## ``attestation-agent`` — the daemon an attested instance answers a
## challenge with.
##
## ## Surface
##
##   attestation-agent serve [--listen=HOST:PORT] [--tier=NAME]
##       [--generation=TOKEN] [--measurement-manifest=PATH]
##       [--config-fingerprint=TOKEN] [--verity-root-hash=HEX]
##       [--provisioned-secrets-dir=PATH]
##       [--tpm-device=ENDPOINT] [--tpm-event-log=PATH]
##   attestation-agent systemd-unit [--binary=PATH] [--listen=HOST:PORT]
##       [--tier=NAME] [--measurement-manifest=PATH]
##       [--provisioned-secrets-dir=PATH]
##       [--tpm-device=ENDPOINT] [--tpm-event-log=PATH]
##   attestation-agent remote-unseal --broker=URL [--volume=DEVICE:MAPPING]…
##
## ``remote-unseal`` is the early-boot half and is documented in
## ``unseal_cli``: this machine attests to a broker, and either receives
## the key to its own state volumes or opens nothing. Its flags are parsed
## by that module rather than by the table below, because the two commands
## share no option but ``--tier`` and folding them into one record would
## let a flag meant for the daemon be accepted by the boot client.
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
## Two tiers are implemented in this build: ``mock``, whose root of
## trust does not exist and says so, and ``tpm``, which runs
## ``TPM2_Quote`` against the endpoint ``--tpm-device`` names and ships
## the platform event log from ``--tpm-event-log`` beside it. Any other
## tier is named in the refusal so that a machine configured for one
## gets a message saying which backend is missing, rather than being
## quietly served by the one backend that always works.
##
## ``--tier=tpm`` is a demand and not a preference. The endpoint is
## opened and the registers are read while the daemon starts, so a
## machine with no TPM — or one whose event log is not exposed — fails
## to start rather than serving reports from the tier it was not asked
## for.
##
## ## Refusals
##
## Every refusal is exit 2 and names what was wrong.

import std/[net, os, strutils]

import repro_attest
import repro_attest/x25519_kem

import ./agent
import ./httpd
import ./secrets
import ./unit
import ./unseal_cli

const
  TierMock = "mock"
  TierTpm = "tpm"

  ImplementedTiers = [TierMock, TierTpm]

static:
  # The flag's vocabulary is the schema's, not a second list that looks
  # like it. A tier spelled here that the report envelope does not
  # define would be a daemon that starts and then builds a document
  # nothing can parse, so it does not compile instead.
  var defined: seq[string] = @[]
  for t in AttestationTier: defined.add $t
  for t in ImplementedTiers:
    doAssert t in defined,
      "attestation-agent names a tier the report schema does not: " & t

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
    tpmDevice*: string
      ## Where the TPM is: a character device path, ``tcp:HOST:PORT`` or
      ## ``unix:PATH``. Read only by the ``tpm`` tier.
    tpmEventLog*: string
      ## Where this platform's measurement log is exposed. Read only by
      ## the ``tpm`` tier.

proc renderUsage*(): string =
  """usage: attestation-agent <subcommand> [options]

Subcommands:
  serve          run the agent
  systemd-unit   print the service unit for these options
  remote-unseal  attest to a broker for this machine's state-volume key

Options:
      --listen HOST:PORT            listen address (default """ &
    DefaultListen & """)
      --tier NAME                   root-of-trust tier; this build
                                    implements """ &
    # The newline is explicit: Nim strips the one immediately after a
    # `"""`, so without it this option and the next share a line.
    ImplementedTiers.join(", ") & "\n" & """      --tpm-device ENDPOINT         --tier=""" & TierTpm & """ only: the TPM, as a
                                    device path, tcp:HOST:PORT or
                                    unix:PATH (default """ &
    DefaultTpmDevicePath & """)
      --tpm-event-log PATH          --tier=""" & TierTpm & """ only: this platform's
                                    measurement log (default """ &
    DefaultTpmEventLogPath & """)
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
  result.tpmDevice = DefaultTpmDevicePath
  result.tpmEventLog = DefaultTpmEventLogPath
  var tpmFlags: seq[string] = @[]
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
    of "--tpm-device":
      result.tpmDevice = valueFor(args, i, "--tpm-device")
      tpmFlags.add "--tpm-device"
    of "--tpm-event-log":
      result.tpmEventLog = valueFor(args, i, "--tpm-event-log")
      tpmFlags.add "--tpm-event-log"
    else:
      raise newException(ValueError, "unknown attestation-agent flag: " & a)

  # Checked after the loop rather than inside it, because `--tier` may
  # appear after the flag it governs and a rule enforced in flag order
  # would depend on the order somebody typed them in.
  if tpmFlags.len > 0 and result.tier != TierTpm:
    raise newException(ValueError,
      tpmFlags.join(" and ") & " configure the " & TierTpm &
      " tier and this command line asks for " & result.tier.escape() &
      "; a flag accepted where it does nothing is a flag an operator " &
      "will one day believe did something")

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
  # Carried only for the tier that reads them. A unit that wrote them
  # under another tier would render an ExecStart this binary's own
  # parser refuses, which is a machine that does not boot its agent.
  if o.tier == TierTpm:
    result.tpmDevice = o.tpmDevice
    result.tpmEventLog = o.tpmEventLog

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

proc unimplementedTierMessage*(tier: string): string =
  ## Why a tier was refused, spelled once.
  ##
  ## Two callers read it — the start-up check that runs before anything
  ## is opened, and the construction itself — and a second wording would
  ## make the refusal depend on which of them got there first.
  var known: seq[string] = @[]
  for t in AttestationTier: known.add $t
  "--tier " & tier.escape() & " is not implemented by this build, " &
    "which implements " & ImplementedTiers.join(" and ") &
    ". The tiers the schema defines are " & known.join(", ") &
    ". This is a refusal rather than a fallback: an agent that " &
    "answered with mock evidence because a device node was missing " &
    "would make a failed attestation look like a successful one."

proc newDriverFor*(o: Options): AttestationDriver =
  ## The backend this command line asks for.
  ##
  ## Exported because it is the one mapping from options to a root of
  ## trust, and a gate that built its own would prove nothing about what
  ## the daemon does. A tier this build does not implement raises, and
  ## nothing here falls back: an agent that answered with mock evidence
  ## because a device node was missing would make a failed attestation
  ## look like a successful one.
  case o.tier
  of TierMock:
    newMockDriver()
  of TierTpm:
    # Both halves are opened here, while the caller is still a start-up
    # path that can refuse. The transport is a real connection and the
    # probe is a real pair of TPM commands, so a machine that cannot
    # attest says so now rather than when somebody asks it to.
    let driver = newTpm2DeviceDriver(newTpm2Transport(o.tpmDevice),
                                     o.tpmEventLog)
    let readiness = driver.driverProbe()
    if not readiness.ready:
      driver.driverClose()
      raise newException(ValueError,
        "--tier=" & TierTpm & " was asked for and this machine cannot " &
        "serve it: " & readiness.detail)
    driver
  else:
    raise newException(ValueError, unimplementedTierMessage(o.tier))

proc runServe(o: Options): int =
  # The tier NAME is checked before anything is opened or created, so a
  # machine configured for a backend this build does not carry is
  # refused without a device being touched. The tier's own readiness is
  # a separate question and is answered in `newDriverFor`.
  if o.tier notin ImplementedTiers:
    stderr.writeLine("attestation-agent: " &
      unimplementedTierMessage(o.tier))
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

  # Created and CHECKED before the socket is bound, so a directory that
  # cannot be made -- or that is not a filesystem a released secret may
  # land on -- is a start-up failure rather than a provisioning failure
  # hours later, discovered by whoever was waiting for the secret.
  var store: ProvisionedSecretStore
  if o.provisionedSecretsDir.len > 0:
    try:
      if not dirExists(o.provisionedSecretsDir):
        createDir(o.provisionedSecretsDir)
      # Narrowed rather than left at whatever the umask allowed. The unit
      # this binary renders asks systemd for 0700; a daemon started by
      # hand gets the same directory.
      setFilePermissions(o.provisionedSecretsDir,
        {fpUserRead, fpUserWrite, fpUserExec})
      store = newProvisionedSecretStore(o.provisionedSecretsDir)
    except CatchableError as err:
      stderr.writeLine("attestation-agent: cannot use " &
        o.provisionedSecretsDir & " for released secrets: " & err.msg)
      return 1

  var driver: AttestationDriver
  try:
    driver = newDriverFor(o)
  except CatchableError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2

  # The device handle and whatever the backend loaded into the TPM. A
  # daemon that exited cleanly and left a transient object behind would
  # leak an object slot on every restart.
  #
  # `defer` and not a call at the end of the proc, because the two
  # failures below this line return without reaching the end: a daemon
  # that refused to START would then hold the device AND leave the
  # transient object loaded, which is the same leak with nobody left to
  # notice it. `defer` covers every exit from here on, including one
  # added later. It is placed after the construction rather than before,
  # so it only ever closes a driver that exists; `newDriverFor` closes
  # its own on the path where the probe refuses.
  defer: driver.driverClose()

  var agent: AttestationAgent
  try:
    agent = newAttestationAgent(
      driver = driver,
      identity = AgentIdentity(
        generation: o.generation,
        configFingerprint: o.configFingerprint,
        verityRootHash: o.verityRootHash),
      keySource = newX25519KeySource(),
      secretStore = store,
      manifestText = manifestText)
  except CatchableError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2

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
  return 0

proc runSystemdUnit(o: Options): int =
  try:
    stdout.write(renderServiceUnit(unitOptionsFor(o)))
  except ValueError as err:
    stderr.writeLine("attestation-agent: " & err.msg)
    return 2
  0

proc runAttestationAgent*(args: seq[string]): int =
  # Dispatched BEFORE `parseArgs`, because `remote-unseal` has its own
  # option table. A subcommand whose flags were parsed by the daemon's
  # parser first would accept `--listen` on a boot client, and a flag
  # accepted where it means nothing is a flag an operator will one day
  # believe did something.
  if args.len > 0 and args[0] == "remote-unseal":
    return runRemoteUnseal(args[1 .. ^1])
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
