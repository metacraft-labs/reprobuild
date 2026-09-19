## ``unseal-broker`` — the entry point the evidence harness runs.
##
## Everything it does lives in ``unseal_broker_core``, so that the broker
## a gate stands up in a thread and the broker a real guest attests to
## over a socket are the same code. A second implementation for the
## in-process case would be a second answer to "what does the broker do",
## and the experiment rests on there being one.
##
## Named without a ``t_`` prefix: it is a program the harness runs, not a
## registered test.
##
## ## Mocking
##
## None. See ``unseal_broker_core``.

import std/[net, os, parseopt, strutils, times]

import repro_attest_agent/httpd
import repro_attest_agent/limits
import repro_attest_agent/remote_unseal

import ./unseal_broker_core

type
  Options = object
    listen: string
    config: BrokerConfig
    keyFile: string

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("unseal-broker: " & msg)
  quit(2)

proc parseArgs(): Options =
  result.listen = "127.0.0.1:0"
  result.config.secretName = DefaultUnsealSecretName
  var p = initOptParser(commandLineParams())
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdLongOption, cmdShortOption:
      case p.key
      of "listen": result.listen = p.val
      of "out": result.config.outDir = p.val
      of "key-file": result.keyFile = p.val
      of "name": result.config.secretName = p.val
      of "policy": result.config.policySource = p.val
      of "require-root-of-trust": result.config.requireRootOfTrust = true
      else: fail("unknown option --" & p.key)
    of cmdArgument: fail("unexpected argument " & p.key.escape())
  for (flag, value) in {"--out": result.config.outDir,
                        "--key-file": result.keyFile,
                        "--policy": result.config.policySource}:
    if value.len == 0: fail(flag & " is required")

when isMainModule:
  var o = parseArgs()
  o.config.secret = readFile(o.keyFile)
  if o.config.secret.len == 0: fail("the key file is empty")
  o.config.policyText = readFile(o.config.policySource)

  let colon = o.listen.rfind(':')
  if colon <= 0: fail("--listen must be HOST:PORT")
  let host = o.listen[0 ..< colon]
  let port = Port(parseInt(o.listen[colon + 1 .. ^1]))

  let broker = newUnsealBroker(o.config)
  let handler = proc (req: HttpRequest): HttpResponse {.gcsafe.} =
    {.cast(gcsafe).}:
      brokerRespond(broker, req, int64(epochTime() * 1000.0))
  let server = newHttpServer(host, port, defaultAgentLimits(), handler,
                             brokerRouteCost)
  writeFile(o.config.outDir / "broker-port", $int(server.boundPort))
  echo "unseal-broker: serving " & host & ":" & $int(server.boundPort) &
    " holding " & o.config.secretName
  flushFile(stdout)
  server.serve()
  server.close()
