## ``attestation-agent remote-unseal`` — the early-boot command that asks
## a broker for this machine's state-volume key and opens the volumes
## with it, or opens nothing.
##
## ## Surface
##
##   attestation-agent remote-unseal --broker=URL [--action=open|format]
##       [--name=NAME] [--tier=NAME] [--generation=TOKEN]
##       [--config-fingerprint=TOKEN] [--verity-root-hash=HEX]
##       [--volume=DEVICE:MAPPING]... [--cryptsetup=PATH]
##       [--report=PATH] [--timeout-seconds=N] [--wait-seconds=N]
##
## ## Where the fail-closed property lives, and where it does not
##
## It lives in ``remote_unseal``: a refusal is a variant with no key field
## on it, reachable only through ``withReleasedKey``. This module is the
## consumer that makes that worth having, and its whole job is to have
## **exactly one** call site for the program that opens a volume, sitting
## inside that callback. On the refusal branch the callback does not run,
## so no ``cryptsetup`` process is created at all — which is a thing a
## gate can *measure* from outside, by handing this command a
## ``--cryptsetup`` that records every invocation and finding the record
## empty.
##
## That measurement is the point. "It does not fall back" asserted about
## source text is a claim about source text; asserted about a recorder
## that the refusing run never touched, it is a claim about the program.
##
## ## The key goes on standard input and nowhere else
##
## Not a file — a released volume key written to a file in an initramfs is
## a key on a filesystem, which is the whole thing this arrangement exists
## to avoid, and the filesystem an initramfs uses is not this module's to
## assume is volatile. Not an argument either: every argument of every
## process on a machine is world-readable through ``/proc``, so a key on a
## command line is a key published to every local account for as long as
## the process lives. ``requireKeyNotOnCommandLine`` is the rule, it is
## enforced before the process is created, and it has its own input in the
## gate.
##
## ## Exit codes
##
## 0 the volumes were opened; 2 usage or refusal to run; 3 the broker did
## not release a key, and nothing was opened; 4 a key was released and a
## volume would not open. Three and four are separated because they are
## different situations for whoever is looking at a machine that did not
## come up: one is about the broker, the other is about the disk.
##
## ## Mocking
##
## None. ``--cryptsetup`` names a program and the program is executed; the
## gates point it at the real ``cryptsetup`` when they have a volume and
## at a recording program when what they are measuring is whether it ran
## at all. A recorder is not a stand-in for ``cryptsetup`` — nothing here
## pretends a volume was opened — it is an instrument on the question
## "was anything executed".

import std/[os, osproc, streams, strutils, times]

import repro_core/ambient_execution

import nimcrypto/[hash, sha2]

import repro_attest
import repro_attest/x25519_kem

import ./agent
import ./remote_unseal

type
  VolumeSpec* = object
    ## One encrypted block device and the name its mapping takes.
    device*: string
    mapping*: string

  VolumeAction* = enum
    ## What the released key is used for.
    ##
    ## ``vaFormat`` is here because a machine whose volumes are keyed by a
    ## broker has to be able to *create* them, and the alternative is the
    ## arrangement this whole command exists to avoid: a key written to a
    ## file so that something else can format with it. The key stays
    ## inside ``withReleasedKey`` for both actions and reaches the opener
    ## on standard input for both.
    vaOpen = "open"
    vaFormat = "format"

  UnsealOptions* = object
    action*: VolumeAction
    broker*: string
    name*: string
    tier*: string
    generation*: string
    configFingerprint*: string
    verityRootHash*: string
    volumes*: seq[VolumeSpec]
    cryptsetup*: string
    reportPath*: string
    timeoutSeconds*: int
    waitSeconds*: int

const
  UnsealTierMock* = "mock"
  DefaultCryptsetup* = "cryptsetup"
  DefaultUnsealTimeoutSeconds* = 20
  DefaultUnsealWaitSeconds* = 0

  ExitUnsealed* = 0
  ExitUsage* = 2
  ExitBrokerRefused* = 3
  ExitVolumeWouldNotOpen* = 4

proc renderUnsealUsage*(): string =
  """usage: attestation-agent remote-unseal --broker URL [options]

Options:
      --action open|format          open the volumes, or create them
      --broker URL                  the unseal broker to attest to
      --name NAME                   the secret to ask for (default """ &
    DefaultUnsealSecretName & ")\n" & """
      --tier NAME                   root-of-trust tier; this build
                                    implements """ & UnsealTierMock & "\n" & """
      --generation TOKEN            the generation this boot is running
      --config-fingerprint TOKEN    this boot's configuration fingerprint
      --verity-root-hash HEX        this boot's verity root hash
      --volume DEVICE:MAPPING       an encrypted volume to open; repeat
      --cryptsetup PATH             the volume opener to execute
      --report PATH                 write a key=value record here
      --timeout-seconds N           per-request budget
      --wait-seconds N              keep retrying an unreachable broker

Exit codes: 0 opened, 2 usage, 3 the broker released nothing and nothing
was opened, 4 a key was released and a volume would not open.
"""

proc parseVolumeSpec*(raw: string): VolumeSpec =
  ## ``DEVICE:MAPPING``. Both halves are required and neither may be
  ## empty: a mapping with no name is a mapping nothing can find, and a
  ## device with no name is an unlock aimed at nothing.
  let colon = raw.rfind(':')
  if colon <= 0:
    raise newException(ValueError,
      "--volume must be DEVICE:MAPPING, got " & raw.escape())
  result.device = raw[0 ..< colon]
  result.mapping = raw[colon + 1 .. ^1]
  if result.mapping.len == 0:
    raise newException(ValueError,
      "--volume " & raw.escape() & " names no mapping")
  if '/' in result.mapping:
    raise newException(ValueError,
      "--volume " & raw.escape() & " names the mapping " &
      result.mapping.escape() & ", and a device-mapper name is a name " &
      "rather than a path")

proc valueFor(args: openArray[string]; i: var int; flag: string): string =
  let a = args[i]
  if a.len > flag.len and a.startsWith(flag & "="):
    inc i
    return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " requires a value")
  result = args[i + 1]
  i += 2

proc parseUnsealArgs*(args: seq[string]): UnsealOptions =
  ## Hand-rolled, so an unknown flag is a refusal rather than a default.
  result.action = vaOpen
  result.name = DefaultUnsealSecretName
  result.tier = UnsealTierMock
  result.cryptsetup = DefaultCryptsetup
  result.timeoutSeconds = DefaultUnsealTimeoutSeconds
  result.waitSeconds = DefaultUnsealWaitSeconds
  var i = 0
  while i < args.len:
    let a = args[i]
    let flag = (if '=' in a: a[0 ..< a.find('=')] else: a)
    case flag
    of "--action":
      let raw = valueFor(args, i, "--action")
      var matched = false
      var known: seq[string] = @[]
      for cand in VolumeAction:
        known.add $cand
        if $cand == raw:
          result.action = cand
          matched = true
      if not matched:
        raise newException(ValueError,
          "--action " & raw.escape() & " is not one of " & known.join(", "))
    of "--broker": result.broker = valueFor(args, i, "--broker")
    of "--name": result.name = valueFor(args, i, "--name")
    of "--tier": result.tier = valueFor(args, i, "--tier")
    of "--generation": result.generation = valueFor(args, i, "--generation")
    of "--config-fingerprint":
      result.configFingerprint = valueFor(args, i, "--config-fingerprint")
    of "--verity-root-hash":
      result.verityRootHash = valueFor(args, i, "--verity-root-hash")
    of "--volume":
      result.volumes.add parseVolumeSpec(valueFor(args, i, "--volume"))
    of "--cryptsetup": result.cryptsetup = valueFor(args, i, "--cryptsetup")
    of "--report": result.reportPath = valueFor(args, i, "--report")
    of "--timeout-seconds":
      result.timeoutSeconds = parseInt(valueFor(args, i, "--timeout-seconds"))
    of "--wait-seconds":
      result.waitSeconds = parseInt(valueFor(args, i, "--wait-seconds"))
    else:
      raise newException(ValueError,
        "unknown attestation-agent remote-unseal flag: " & a)
  if result.broker.len == 0:
    raise newException(ValueError, "--broker is required")

# ---------------------------------------------------------------------
# Opening a volume
# ---------------------------------------------------------------------

proc unlockArguments*(action: VolumeAction; v: VolumeSpec): seq[string] =
  ## What ``cryptsetup`` is asked to do. Named as its own function so the
  ## argument vector can be checked by value — including by the rule
  ## below, which has to be able to see every element that will be
  ## published in ``/proc``.
  ##
  ## ``--key-file=-`` is standard input, in both actions. It is the whole
  ## of why the key never becomes a file and never becomes an argument.
  ##
  ## Written as a total function over the action enum rather than as an
  ## ``if``, so an action added later has to be given an argument vector
  ## here and the compiler asks for it.
  case action
  of vaOpen:
    @["open", "--type", "luks", "--batch-mode", "--key-file=-",
      v.device, v.mapping]
  of vaFormat:
    # LUKS2, and a deliberately cheap key derivation: the passphrase is a
    # released 256-bit credential rather than something a person typed,
    # so the work factor that protects a human-chosen passphrase buys
    # nothing here and costs an early-boot machine seconds it does not
    # have.
    @["luksFormat", "--type", "luks2", "--batch-mode",
      "--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000",
      "--cipher", "aes-xts-plain64", "--key-size", "512",
      "--key-file=-", v.device]

proc requireKeyNotOnCommandLine*(argv: openArray[string]; key: string) =
  ## Refuse to create a process whose command line carries the key.
  ##
  ## Every argument of every process is readable by every local account
  ## through ``/proc/<pid>/cmdline``, so this is not a style rule: an
  ## argument vector carrying a volume key publishes it for the lifetime
  ## of the process. The check is here, over the vector that is about to
  ## be handed to ``startProcess``, rather than trusted to the shape of
  ## ``unlockArguments`` above — a constructor nobody checks is a
  ## constructor somebody edits.
  if key.len == 0: return
  for i, a in argv:
    if key in a:
      raise newException(ValueError,
        "argument " & $i & " of the volume opener carries the released " &
        "key; every process's arguments are world-readable through " &
        "/proc, so this build hands a key to standard input or not at all")

proc requireAbsoluteOpener*(cryptsetup: string) =
  ## The volume opener is named by an ABSOLUTE PATH, never resolved
  ## through ``PATH``.
  ##
  ## This is the same rule as the one above it and about a different
  ## channel. A bare name resolved at run time asks the environment which
  ## program is about to be handed a volume key, and an early-boot client
  ## is exactly where an environment is least worth asking: the
  ## initramfs sets its own ``PATH``, and a machine that gets that wrong
  ## does not fail, it succeeds against the wrong binary.
  if cryptsetup.len == 0:
    raise newException(ValueError,
      "no volume opener was configured; this build will not guess one")
  if not cryptsetup.isAbsolute:
    raise newException(ValueError,
      "the volume opener " & cryptsetup.escape() & " is not an absolute " &
      "path; a name resolved through PATH lets the environment choose " &
      "which program is handed a volume key, and this build names the " &
      "program instead")

proc openVolume*(cryptsetup: string; action: VolumeAction; v: VolumeSpec;
                 key: string): int =
  ## Execute the opener once, with the key on standard input. Returns its
  ## exit status.
  ##
  ## ``uncontrolledStartProcess`` rather than a typed execution profile,
  ## and that is deliberate rather than an oversight: the program this
  ## runs is whichever ``cryptsetup`` the image it boots on carries, and
  ## it is named by the operator. It is not a build input and it cannot
  ## come out of the store, so the honest spelling is the one that says
  ## so out loud. What this build DOES control is narrowed instead: the
  ## path must be absolute (no ``poUsePath``, so the environment chooses
  ## nothing) and the key never reaches the argument vector.
  requireAbsoluteOpener(cryptsetup)
  let argv = unlockArguments(action, v)
  requireKeyNotOnCommandLine(argv, key)
  var p = uncontrolledStartProcess(cryptsetup, args = argv,
                                   options = {poStdErrToStdOut})
  try:
    let input = p.inputStream
    input.write(key)
    input.flush()
    input.close()
    result = p.waitForExit()
  finally:
    p.close()

# ---------------------------------------------------------------------
# The command
# ---------------------------------------------------------------------

proc sha256Hex(s: string): string = toLowerAscii($sha256.digest(s))

proc reachBroker(t: UnsealTransport; driver: AttestationDriver;
                 keySource: EphemeralKeySource; identity: AgentIdentity;
                 name: string; waitSeconds: int): UnsealOutcome =
  ## One attempt, or several while the broker is still coming up.
  ##
  ## Only ``urBrokerUnreachable`` is retried, and that is the point: a
  ## broker that answered and declined has made a decision, and asking it
  ## again until it changes its mind is the fallback this whole
  ## arrangement exists not to have. A socket that is not listening yet is
  ## not a decision.
  let deadline = epochTime() + float(waitSeconds)
  while true:
    result = performRemoteUnseal(t, driver, keySource, identity, name,
                                 int64(epochTime() * 1000.0))
    if result.decision == udUnsealed: return
    if result.refusal != urBrokerUnreachable: return
    if epochTime() >= deadline: return
    sleep(500)

proc runRemoteUnseal*(args: seq[string]): int =
  var o: UnsealOptions
  try:
    o = parseUnsealArgs(args)
  except ValueError as err:
    stderr.writeLine("attestation-agent remote-unseal: " & err.msg)
    stderr.write(renderUnsealUsage())
    return ExitUsage
  if o.tier != UnsealTierMock:
    stderr.writeLine("attestation-agent remote-unseal: --tier " &
      o.tier.escape() & " is not implemented by this build, which " &
      "implements " & UnsealTierMock & ". This is a refusal rather than " &
      "a fallback: a machine that attested with mock evidence because a " &
      "device node was missing would be handed its disk key on the " &
      "strength of nothing.")
    return ExitUsage

  var lines: seq[string] = @[]
  proc say(k, v: string) = lines.add(k & "=" & v)

  var transport: UnsealTransport
  var outcome: UnsealOutcome
  try:
    transport = newHttpUnsealTransport(o.broker, o.timeoutSeconds * 1000)
    outcome = reachBroker(transport, newMockDriver(), newX25519KeySource(),
      AgentIdentity(generation: o.generation,
                    configFingerprint: o.configFingerprint,
                    verityRootHash: o.verityRootHash),
      o.name, o.waitSeconds)
  except CatchableError as err:
    stderr.writeLine("attestation-agent remote-unseal: " & err.msg)
    return ExitUsage

  say("broker", o.broker)
  say("secret_name", outcome.secretName)
  say("broker_status", $outcome.brokerStatus)
  say("challenge", (if outcome.challengeHex.len == 0: "-"
                    else: outcome.challengeHex))
  say("ephemeral_pub", (if outcome.ephemeralPubHex.len == 0: "-"
                        else: outcome.ephemeralPubHex))
  say("unseal_decision", $outcome.decision)
  case outcome.decision
  of udRefused:
    say("unseal_refusal", $outcome.refusal)
    say("unseal_reason", outcome.reason.replace("\n", " "))
    say("released_key_bytes", "0")
    say("released_key_sha256", "-")
  of udUnsealed:
    say("unseal_refusal", "-")
    say("unseal_reason", "-")
    say("released_key_bytes", $outcome.releasedKeyBytes)

  say("action", $o.action)
  say("volumes_requested", $o.volumes.len)
  say("cryptsetup", o.cryptsetup)

  # THE ONE CALL SITE. Everything that executes the volume opener is
  # inside this callback, and the callback does not run on a refusal.
  var openFailures = 0
  var openedCount = 0
  var openLines: seq[string] = @[]
  let ran = outcome.withReleasedKey(proc (key: string) =
    openLines.add("released_key_sha256=" & sha256Hex(key))
    for v in o.volumes:
      var rc = -1
      try:
        rc = openVolume(o.cryptsetup, o.action, v, key)
      except CatchableError as err:
        openLines.add("open_error_" & v.mapping & "=" &
                      err.msg.replace("\n", " "))
      openLines.add("open_" & v.mapping & "_rc=" & $rc)
      if rc == 0: inc openedCount else: inc openFailures)

  for line in openLines: lines.add line
  say("opener_ran", (if ran: "1" else: "0"))
  say("volumes_opened", $openedCount)

  let status =
    if not ran: ExitBrokerRefused
    elif openFailures > 0: ExitVolumeWouldNotOpen
    else: ExitUnsealed
  say("exit", $status)
  say("end", "1")

  if o.reportPath.len > 0:
    try:
      createDir(o.reportPath.parentDir)
      writeFile(o.reportPath, lines.join("\n") & "\n")
    except CatchableError as err:
      stderr.writeLine("attestation-agent remote-unseal: cannot write " &
        o.reportPath & ": " & err.msg)

  case outcome.decision
  of udUnsealed:
    echo "attestation-agent remote-unseal: opened " & $openedCount & " of " &
      $o.volumes.len & " volume(s)"
  of udRefused:
    stderr.writeLine("attestation-agent remote-unseal: the broker released " &
      "no key (" & $outcome.refusal & "): " & outcome.reason)
    stderr.writeLine("attestation-agent remote-unseal: no volume was " &
      "opened and none will be; this build has no second answer to a " &
      "refusal.")
  status
