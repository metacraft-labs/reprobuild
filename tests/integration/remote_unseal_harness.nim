## Standing a real broker up beside the code under test, and measuring
## whether the volume opener was executed at all.
##
## Two instruments live here and they are different in kind.
##
## **The broker in a thread.** It is the shipped ``unseal_broker_core``,
## on a real socket on a real port, reached by the shipped
## ``HttpUnsealTransport`` over real HTTP. Nothing is stubbed: the same
## code answers the guest in the evidence harness and answers the gates
## here, so a rule that held in one and not the other is not
## constructible.
##
## **The recorder.** ``--cryptsetup`` names a program, and the client
## executes it. To ask "was anything executed at all" a gate has to hand
## the client a program it can observe, so this module makes the TEST
## BINARY ITSELF that program: invoked with ``REMOTE_UNSEAL_RECORDER_LOG``
## set, it appends its argument vector and a digest of its standard input
## to that file and exits. No shell, no second build, and the recorder is
## on every platform the gate is.
##
## A recorder is **not a stand-in for ``cryptsetup``** and nothing here
## pretends a volume was opened. It is an instrument on one question —
## was a process created — and the answer it gives on the refusal path is
## the whole substance of "the client does not fall back": the file is
## empty because nothing ran, and that is a measurement of the program
## rather than a reading of its source.
##
## ## Mocking
##
## The recorder is the only thing here that stands in front of a real
## program, and it is justified above: the property under test is the
## *absence* of an execution, which cannot be observed by executing the
## real thing. Where a volume really is opened — in the evidence harness
## — the real ``cryptsetup`` runs against real LUKS2 volumes, and that
## experiment is what the pinned records come from.

import std/[net, os, strutils, times]

import nimcrypto/[hash, sha2]

import repro_attest_agent/httpd
import repro_attest_agent/limits

import ./attested_boot/unseal_broker_core

const
  RecorderLogEnv* = "REMOTE_UNSEAL_RECORDER_LOG"

  HarnessPolicy* = """schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["mock"]
backends = ["mock"]
allow_mock = true

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 300
require_challenge = true
"""
    ## The same shape the evidence harness writes: the tier with no root
    ## of trust, admitted and said out loud. Whether a release happens
    ## under it is then the broker's separate opt-in.

  HarnessRejectingPolicy* = """schema = "reproos.attestation-policy.v1"

[accept]
tiers = ["tpm"]
backends = ["tpm2"]
allow_mock = false

[measurements]
manifests = []
require_certificates = false

[freshness]
max_challenge_age_seconds = 300
require_challenge = true
"""
    ## A policy that admits no tier this machine has. It produces a
    ## REJECTED verdict rather than a withheld acceptance, so the two
    ## refusals a broker can reach are genuinely two and a gate can show
    ## the client does not tell them apart by accident.

type
  BrokerHarness* = object
    server*: HttpServer
    thread*: Thread[HttpServer]
    port*: Port
    broker*: UnsealBroker
    outDir*: string

proc harnessSha256Hex*(s: string): string =
  ## Named distinctly rather than `sha256Hex`: `repro_attest` exports one
  ## of those, and a gate that imported both would get an ambiguity at
  ## the call site rather than the digest it meant.
  toLowerAscii($sha256.digest(s))

proc runAsRecorderIfAsked*() =
  ## When this binary is started with ``RecorderLogEnv`` set it is not a
  ## test run: it has been executed as the volume opener, and its job is
  ## to say so and get out of the way.
  ##
  ## Called first thing in every gate that uses the recorder. A gate that
  ## forgot would run its whole suite inside the child process, which is
  ## loud rather than silent — the recorder file would fill with test
  ## output and the assertions on it would fail.
  let log = getEnv(RecorderLogEnv)
  if log.len == 0: return
  let argv = commandLineParams()
  let input = readAll(stdin)
  var lines: seq[string] = @[]
  lines.add "argv=" & argv.join(" ")
  lines.add "argc=" & $argv.len
  lines.add "stdin_bytes=" & $input.len
  lines.add "stdin_sha256=" & harnessSha256Hex(input)
  let f = open(log, fmAppend)
  try:
    f.write(lines.join("\n") & "\n")
  finally:
    f.close()
  quit(0)

proc serveThread(s: HttpServer) {.thread.} =
  s.serve()

proc startBroker*(config: BrokerConfig): BrokerHarness =
  ## Port 0, so a gate never collides with a port something else on this
  ## host is using and never has to guess whether it did.
  result.outDir = config.outDir
  result.broker = newUnsealBroker(config)
  let broker = result.broker
  let handler = proc (req: HttpRequest): HttpResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      brokerRespond(broker, req, int64(epochTime() * 1000.0))
  result.server = newHttpServer("127.0.0.1", Port(0), defaultAgentLimits(),
                                handler, brokerRouteCost)
  result.port = result.server.boundPort
  createThread(result.thread, serveThread, result.server)

proc stopBroker*(h: var BrokerHarness) =
  ## Set the flag, then open one connection so the blocked ``accept``
  ## returns and the loop sees it. ``joinThread`` afterwards is what makes
  ## "the broker is still alive" a measured claim rather than an assumed
  ## one: a loop that had died would have been joined already, and one
  ## that had wedged would never join.
  h.server.requestStop()
  try:
    let poke = newSocket()
    poke.connect("127.0.0.1", h.port)
    poke.close()
  except CatchableError:
    discard
  joinThread(h.thread)
  h.server.close()

proc brokerUrl*(h: BrokerHarness): string =
  "http://127.0.0.1:" & $int(h.port)

proc harnessConfig*(outDir, secret: string; requireRootOfTrust = false;
                    policy = HarnessPolicy;
                    secretName = "state-volume-key"): BrokerConfig =
  BrokerConfig(outDir: outDir, secret: secret, secretName: secretName,
               policyText: policy, policySource: "<harness policy>",
               requireRootOfTrust: requireRootOfTrust)

proc recorderInvocations*(path: string): seq[string] =
  ## Every line the recorder wrote, or an empty sequence when it was
  ## never run. The distinction between "the file is empty" and "the file
  ## does not exist" is deliberately erased here: both mean nothing was
  ## executed, and a gate that had to know which would be asserting about
  ## this module rather than about the client.
  if not fileExists(path): return @[]
  for line in readFile(path).splitLines:
    if line.strip().len > 0: result.add line
