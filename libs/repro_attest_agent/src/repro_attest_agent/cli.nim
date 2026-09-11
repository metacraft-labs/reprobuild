## ``attestation-agent`` — the daemon an attested instance answers a
## challenge with.
##
## ## Surface
##
##   attestation-agent serve [--listen=HOST:PORT] [--tier=NAME]
##       [--generation=TOKEN] [--measurement-manifest=PATH]
##       [--config-fingerprint=TOKEN] [--verity-root-hash=HEX]
##       [--provisioned-secrets-dir=PATH]
##   attestation-agent systemd-unit [--binary=PATH] [--listen=HOST:PORT]
##       [--tier=NAME] [--measurement-manifest=PATH]
##       [--provisioned-secrets-dir=PATH]
##
## ``systemd-unit`` prints the service unit for the options it is given.
## The image build calls it instead of carrying a copy, so the flags in
## the unit and the flags this binary parses cannot drift apart.
##
## ## Why the tier is a flag and not a probe
##
## The daemon does not look at the machine and decide what root of trust
## it has. It is told, and it fails if what it was told is not there.
## A daemon that fell back to a weaker tier when a device node was
## missing would answer with mock evidence on a machine that was supposed
## to have a TPM, and the failure would look like a successful
## attestation.
##
## Only the mock tier is implemented in this build. The others are named
## in the refusal so that a machine configured for one gets a message
## saying which backend is missing, rather than being quietly served by
## the one backend that always works.
##
## ## Refusals
##
## Every refusal is exit 2 and names what was wrong.

import std/[net, os, strutils]

import repro_attest

import ./agent
import ./httpd
import ./unit

const
  TierMock = "mock"

type
  Subcommand* = enum
    scServe
    scSystemdUnit
    scNone

  Options* = object
    ## Exported so that the service unit this binary renders can be fed
    ## back through the parser this binary uses. A unit whose ExecStart
    ## the daemon cannot parse is a machine that does not boot its agent,
    ## and the two halves are only one file apart — which is exactly the
    ## distance at which a renamed flag goes unnoticed.
    sub*: Subcommand
    listen*: string
    tier*: string
    generation*: string
    manifestPath*: string
    configFingerprint*: string
    verityRootHash*: string
    provisionedSecretsDir*: string
    binaryPath*: string

proc renderUsage*(): string =
  """usage: attestation-agent <subcommand> [options]

Subcommands:
  serve          run the agent
  systemd-unit   print the service unit for these options

Options:
      --listen HOST:PORT            listen address (default """ &
    DefaultListen & """)
      --tier NAME                   root-of-trust tier; this build
                                    implements """ & TierMock & """
      --generation TOKEN            the generation this boot is running
      --measurement-manifest PATH   the baked-in measurement manifest
      --config-fingerprint TOKEN    only without --measurement-manifest
      --verity-root-hash HEX        only without --measurement-manifest
      --provisioned-secrets-dir PATH  where released secrets are placed
      --binary PATH                 systemd-unit: the installed binary

Exit codes: 0 success, 1 runtime failure, 2 usage or refusal.
"""

proc valueFor(args: openArray[string]; i: var int; flag: string): string =
  let a = args[i]
  if a.len > flag.len and a.startsWith(flag & "="):
    inc i
    return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " requires a value")
  result = args[i + 1]
  i += 2

proc parseArgs*(args: seq[string]): Options =
  ## Hand-rolled so every unknown flag is a refusal rather than a
  ## default.
  result.listen = DefaultListen
  result.tier = TierMock
  result.provisionedSecretsDir = DefaultProvisionedSecretsDir
  result.binaryPath = DefaultInstalledBinary
  if args.len == 0:
    result.sub = scNone
    return
  case args[0]
  of "serve": result.sub = scServe
  of "systemd-unit": result.sub = scSystemdUnit
  else:
    raise newException(ValueError,
      "unknown attestation-agent subcommand: " & args[0])
  var i = 1
  while i < args.len:
    let a = args[i]
    let flag = (if '=' in a: a[0 ..< a.find('=')] else: a)
    case flag
    of "--listen": result.listen = valueFor(args, i, "--listen")
    of "--tier": result.tier = valueFor(args, i, "--tier")
    of "--generation": result.generation = valueFor(args, i, "--generation")
    of "--measurement-manifest":
      result.manifestPath = valueFor(args, i, "--measurement-manifest")
    of "--config-fingerprint":
      result.configFingerprint = valueFor(args, i, "--config-fingerprint")
    of "--verity-root-hash":
      result.verityRootHash = valueFor(args, i, "--verity-root-hash")
    of "--provisioned-secrets-dir":
      result.provisionedSecretsDir =
        valueFor(args, i, "--provisioned-secrets-dir")
    of "--binary": result.binaryPath = valueFor(args, i, "--binary")
    else:
      raise newException(ValueError, "unknown attestation-agent flag: " & a)

proc unitOptionsFor*(o: Options): UnitOptions =
  ## The one mapping from parsed options to the unit that will reproduce
  ## them. Used by ``systemd-unit`` and by the gate that feeds the result
  ## back through ``parseArgs``.
  result = defaultUnitOptions()
  result.binaryPath = o.binaryPath
  result.listen = o.listen
  result.tier = o.tier
  result.measurementManifest = o.manifestPath
  result.provisionedSecretsDir = o.provisionedSecretsDir

proc splitListen(listen: string): (string, Port) =
  let colon = listen.rfind(':')
  if colon <= 0:
    raise newException(ValueError,
      "--listen must be HOST:PORT, got " & listen.escape())
  let host = listen[0 ..< colon]
  let port = try:
      parseInt(listen[colon + 1 .. ^1])
    except ValueError:
      raise newException(ValueError,
        "--listen port is not a number in " & listen.escape())
  if port < 0 or port > 65535:
    raise newException(ValueError,
      "--listen port " & $port & " is outside 0..65535")
  (host, Port(port))

proc runServe(o: Options): int =
  if o.tier != TierMock:
    var known: seq[string] = @[]
    for t in AttestationTier: known.add $t
    stderr.writeLine("attestation-agent: --tier " & o.tier.escape() &
      " is not implemented by this build, which implements " & TierMock &
      ". The tiers the schema defines are " & known.join(", ") &
      ". This is a refusal rather than a fallback: an agent that answered " &
      "with mock evidence because a device node was missing would make a " &
      "failed attestation look like a successful one.")
    return 2

  var manifestText = ""
  if o.manifestPath.len > 0:
    if not fileExists(o.manifestPath):
      stderr.writeLine("attestation-agent: no measurement manifest at " &
        o.manifestPath)
      return 2
    manifestText = readFile(o.manifestPath)
    if o.configFingerprint.len > 0 or o.verityRootHash.len > 0:
      stderr.writeLine("attestation-agent: --config-fingerprint and " &
        "--verity-root-hash are not accepted alongside " &
        "--measurement-manifest; the manifest is the build's answer and " &
        "the command line is not entitled to a second one")
      return 2

  var host: string
  var port: Port
  try:
    (host, port) = splitListen(o.listen)
  except ValueError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2

  var agent: AttestationAgent
  try:
    agent = newAttestationAgent(
      driver = newMockDriver(),
      identity = AgentIdentity(
        generation: o.generation,
        configFingerprint: o.configFingerprint,
        verityRootHash: o.verityRootHash),
      keySource = newMockKeySource(),
      manifestText = manifestText)
  except CatchableError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2

  # Created before the socket is bound, so a directory that cannot be
  # made is a start-up failure rather than a provisioning failure hours
  # later.
  if o.provisionedSecretsDir.len > 0 and
     not dirExists(o.provisionedSecretsDir):
    try:
      createDir(o.provisionedSecretsDir)
    except OSError as err:
      stderr.writeLine("attestation-agent: cannot create " &
        o.provisionedSecretsDir & ": " & err.msg)
      return 1

  var server: HttpServer
  try:
    server = newAgentServer(agent, host, port)
  except CatchableError as err:
    stderr.writeLine("attestation-agent: cannot listen on " & o.listen &
      ": " & err.msg)
    return 1
  echo "attestation-agent: serving " & $agent.tier & "/" & $agent.backend &
    " on " & host & ":" & $server.boundPort
  server.serve()
  server.close()
  0

proc runSystemdUnit(o: Options): int =
  try:
    stdout.write(renderServiceUnit(unitOptionsFor(o)))
  except ValueError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2
  0

proc runAttestationAgent*(args: seq[string]): int =
  var opts: Options
  try:
    opts = parseArgs(args)
  except ValueError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    stderr.write(renderUsage())
    return 2
  case opts.sub
  of scServe: runServe(opts)
  of scSystemdUnit: runSystemdUnit(opts)
  of scNone:
    stderr.write(renderUsage())
    2
