## The cloud launch adapter's dry-run path creates no cloud resource —
## asserted, with instruments that are shown to be capable of saying the
## opposite.
##
## ## Why "nothing happened" needs more care than "something happened"
##
## Every assertion in this file is a NEGATIVE: no effector was called,
## no process was started, no socket was opened, no file was written. A
## negative is satisfied by an instrument that is broken, by a subject
## that was never reached, and by a code path that does something
## different from the one that matters — three ways to be green while
## measuring nothing. So each instrument here carries its own **negative
## control**: a case that makes it report the opposite, on this run, in
## this process. An instrument that has not been seen to fire is not an
## instrument, it is a habit.
##
## The four instruments, each with its control:
##
##   1. **The effector seam.** A recording effector counts calls. The
##      dry run must call it zero times; the armed path, given the same
##      effector, must call it exactly once with exactly the invocation
##      the dry run returned.
##   2. **Processes.** Shims named after the provider command-line tools
##      are put on `PATH`; each records the argument vector it was run
##      with. The dry run must leave no record. The control runs one
##      shim from this very process and requires a record to appear.
##   3. **Sockets.** The process's own open file descriptors are counted
##      by kind. The dry run must not change the count. The control
##      opens a socket, requires the count to rise, closes it, and
##      requires it to fall back.
##   4. **Files.** A scratch directory is enumerated before and after.
##      The dry run must leave it as it found it. The control asks the
##      command to write its manifest and requires exactly one file.
##
## ## The dry run is not a different, harmless path
##
## The strongest way to satisfy "the dry run creates nothing" is for the
## dry run to be a stub. So the two modes are required to produce the
## SAME invocation, the SAME manifest and the SAME identity: the dry run
## does all of the armed path's work and stops at its last statement.
## Without that, this whole file would be a statement about code nobody
## uses.
##
## ## And there is nothing in this build that could launch anything
##
## A source scan over `libs/` and `apps/` requires **zero** call sites
## of the procedure that would hand an invocation to an effector, and
## zero mentions of the armed mode outside the module that defines it.
## The scanner is given a file that DOES contain both — this one — and
## required to find them, so a scanner that matched nothing cannot pass
## by matching nothing.
##
## ## Mocking
##
## The effector and the provider shims are not mocks of a cloud. There
## is no cloud in this test and nothing stands in for one: the effector
## is a recording implementation of the seam whose *number of
## invocations* is the measurement, and the shims are real executables
## whose *absence of invocation* is the measurement. Neither returns a
## fabricated provider response, because nothing here reads one.

import std/[algorithm, net, os, strutils, unittest]

import repro_attest
import repro_attest_verify
import repro_cli_support/attest

include ./attestation_verifier_harness
include ./snp_digest_vectors

let scratch = getTempDir() / "repro-cloud-dry-run-" & $getCurrentProcessId()

proc scratchDir(name: string): string =
  result = scratch / name
  createDir(result)

# Standard error is redirected for the whole gate rather than per call,
# because restoring it portably is not worth a second mechanism; the
# offsets make each invocation's output readable on its own. The gate's
# own failures print on standard output, which is untouched.
let stderrLog = (createDir(scratch); scratch / "stderr.log")
doAssert (writeFile(stderrLog, ""); reopen(stderr, stderrLog, fmWrite))

proc runAttestCommandIn(args: seq[string]): int =
  ## The command, run against a STATED environment — the empty one.
  ##
  ## Every library call in this file already said which environment it
  ## meant, and every case that went through the command still read the
  ## process environment, so this gate was a statement about the machine
  ## it ran on: measured, one exported variable whose value the probe
  ## plan legitimately spells took it from 17 passing cases to 13 with
  ## 4 failures and exit 1.
  runAttestCommand(args, fixedEnvLookup([]))

proc runCapturing(args: seq[string]): tuple[code: int; err: string] =
  flushFile(stderr)
  let before = getFileSize(stderrLog)
  result.code = runAttestCommandIn(args)
  flushFile(stderr)
  var f: File
  doAssert open(f, stderrLog, fmRead)
  f.setFilePos(before)
  result.err = f.readAll()
  f.close()

proc bytesOfHexString(h: string): string =
  doAssert h.len mod 2 == 0
  result = newString(h.len div 2)
  for i in 0 ..< result.len:
    result[i] = char(parseHexInt(h[2 * i .. 2 * i + 1]))

let launchFirmware = bytesOfHexString(UpstreamOvmfAmdSevSuffixHex)

const
  FixtureFingerprint = "reproos-attested-uefi:cloud-launch"
  FixtureUki = "not-a-real-unified-kernel-image"

let cliDir = scratchDir("cli-inputs")
let cliFirmwarePath = cliDir / "firmware.bin"
let cliUkiPath = cliDir / "uki.bin"
writeFile(cliFirmwarePath, launchFirmware)
writeFile(cliUkiPath, FixtureUki)

proc probeSpec(): CloudLaunchSpec =
  ## One launch, on the cloud this build has a model for. Every
  ## identifier is a fabricated placeholder: this gate launches nothing,
  ## so it needs no real region, image, network or key, and a fixture
  ## carrying one would publish it.
  CloudLaunchSpec(
    provider: cpAwsEc2,
    region: "us-east-1",
    instanceName: "reproos-attest-probe",
    instanceShape: "m6a.2xlarge",
    imageReference: "ami-0fixture000000000",
    subnet: "subnet-0fixture000000000",
    sshKeyReference: "reproos-attest-probe-key",
    firmware: launchFirmware,
    machineModel: "EPYC-Milan",
    guestPolicy: "0x30000",
    guestFeatures: "0x21",
    configFingerprint: FixtureFingerprint,
    ukiImage: FixtureUki,
    verityImageDigest: "sha256:" & repeat('5', 64),
    verityRootHash: repeat('4', 64))

proc launchArgs(): seq[string] =
  ## The command-line spelling of exactly the launch `probeSpec`
  ## describes, so the library path and the command path are the same
  ## launch and a difference between them is a finding rather than a
  ## difference of inputs.
  @["launch",
    "--provider", "aws-ec2",
    "--region", "us-east-1",
    "--instance-name", "reproos-attest-probe",
    "--instance-shape", "m6a.2xlarge",
    "--image-reference", "ami-0fixture000000000",
    "--subnet", "subnet-0fixture000000000",
    "--ssh-key-reference", "reproos-attest-probe-key",
    "--firmware", cliFirmwarePath,
    "--vcpu-type", "EPYC-Milan",
    "--guest-policy", "0x30000",
    "--guest-features", "0x21",
    "--config-fingerprint", FixtureFingerprint,
    "--uki", cliUkiPath,
    "--verity-image-digest", "sha256:" & repeat('5', 64),
    "--verity-root-hash", repeat('4', 64)]

# ---------------------------------------------------------------------
# Instrument 2: the provider command-line shims
# ---------------------------------------------------------------------

const
  ProviderTools = ["aws", "gcloud", "az", "terraform", "tofu", "curl"]
    ## Every program that could reach a cloud from here. `curl` is on
    ## the list because an adapter that decided to speak the provider's
    ## HTTP interface directly would most cheaply do it that way, and a
    ## list of the three official tools would not notice.

let shimDir = scratchDir("path-shims")
let shimRecord = scratch / "shim-invocations.log"

proc installShims() =
  for tool in ProviderTools:
    let path = shimDir / tool
    writeFile(path, "#!/bin/sh\n" &
      "printf '%s' \"$0\" >> " & shimRecord & "\n" &
      "for a in \"$@\"; do printf ' %s' \"$a\" >> " & shimRecord & "; done\n" &
      "printf '\\n' >> " & shimRecord & "\n" &
      "exit 0\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc shimInvocations(): int =
  if not fileExists(shimRecord): return 0
  for line in readFile(shimRecord).splitLines:
    if line.strip().len > 0: inc result

# ---------------------------------------------------------------------
# Instrument 3: this process's own open descriptors
# ---------------------------------------------------------------------

const ProcFdRoot = "/proc/self/fd"

proc socketFdCount(root: string): int =
  ## How many of this process's descriptors are sockets, or **-1** when
  ## the instrument's own source is not present.
  ##
  ## The difference matters more than the number: a counter that
  ## returned 0 where it cannot look would satisfy "no socket was
  ## opened" on every platform that does not publish this directory,
  ## which is the shape where an instrument's blindness reads as a pass.
  if not dirExists(root): return -1
  result = 0
  for _, path in walkDir(root):
    var target = ""
    try:
      target = expandSymlink(path)
    except OSError, IOError:
      continue
    if target.startsWith("socket:"): inc result

# ---------------------------------------------------------------------
# Instrument 4: a directory, enumerated
# ---------------------------------------------------------------------

proc entriesOf(dir: string): seq[string] =
  for _, path in walkDir(dir): result.add path.extractFilename
  result.sort()

# ---------------------------------------------------------------------
# The effector, and the counters that are the measurement
# ---------------------------------------------------------------------

type
  EffectorLedger = ref object
    calls: int
    lastArgv: seq[string]
    lastEnvNames: seq[string]

proc recordingEffector(ledger: EffectorLedger): CloudEffector =
  ## An implementation of the seam that records and returns. It reaches
  ## no cloud — there is nothing in this build that could — and that is
  ## why the number it records is the measurement rather than a
  ## substitute for one.
  result = proc (effect: CloudEffect): int =
    inc ledger.calls
    ledger.lastArgv = effect.argv
    ledger.lastEnvNames = effect.providerEnvNames
    0

# ---------------------------------------------------------------------
# The source scan, with its own negative control
# ---------------------------------------------------------------------

proc occurrencesIn(path, needle: string): int =
  ## Occurrences in the file's RAW bytes.
  ##
  ## Deliberately not over a comment-stripped reading. Stripping at the
  ## first `#` truncates any line carrying one inside a string literal,
  ## and a scan that can lose part of a line can lose the call site it
  ## is looking for — which would turn a blind spot into a pass. Over
  ## raw bytes the count is an OVER-estimate, and an over-estimate that
  ## comes back zero is the stronger statement: not merely "nothing
  ## calls it" but "nothing in the shipped tree so much as spells it".
  let text = readFile(path)
  var i = 0
  while true:
    let at = text.find(needle, i)
    if at < 0: break
    inc result
    i = at + needle.len

iterator nimSourcesUnder(root: string): string =
  for path in walkDirRec(root):
    if path.endsWith(".nim"): yield path

let repoRoot = currentSourcePath().parentDir.parentDir.parentDir

# ---------------------------------------------------------------------

suite "the seam: the dry run does not reach it and the armed path does":

  test "a dry run calls the effector zero times":
    let ledger = EffectorLedger()
    let outcome = performCloudLaunch(probeSpec(), clmDryRun,
      recordingEffector(ledger), fixedEnvLookup([]))
    check ledger.calls == 0
    check outcome.effectsAttempted == 0
    check outcome.effectStatus == 0
    # …and it did the work, so the zero above is not the zero of a
    # procedure that returned early.
    check outcome.plan.len >= 12
    check outcome.identity.startsWith(DigestPrefix)
    check outcome.manifestText.len > 0

  test "the SAME effector fires exactly once when the launch is armed":
    # The negative control for the counter above. Without it, "zero" is
    # satisfied by an effector that could never be called at all.
    let ledger = EffectorLedger()
    let spec = probeSpec()
    let dry = performCloudLaunch(spec, clmDryRun, recordingEffector(ledger),
      fixedEnvLookup([]))
    check ledger.calls == 0
    let armed = performCloudLaunch(spec, clmArmed, recordingEffector(ledger),
      fixedEnvLookup([]))
    check ledger.calls == 1
    check armed.effectsAttempted == 1
    # What it was handed is exactly what the dry run returned, so the
    # dry run is a description of the request that WOULD be made and
    # not of some other request.
    check ledger.lastArgv == dry.plan
    check ledger.lastArgv == armed.plan

  test "the dry run and the armed path produce the same work":
    # The defence against the strongest way to pass this whole file: a
    # dry run that is a stub. Everything an armed launch computes, the
    # dry run computes.
    let ledger = EffectorLedger()
    let spec = probeSpec()
    let dry = performCloudLaunch(spec, clmDryRun, recordingEffector(ledger),
      fixedEnvLookup([]))
    let armed = performCloudLaunch(spec, clmArmed, recordingEffector(ledger),
      fixedEnvLookup([]))
    check dry.plan == armed.plan
    check dry.manifestText == armed.manifestText
    check dry.identity == armed.identity
    check dry.manifestText.len > 200
    check ledger.calls == 1

  test "an armed launch with no effector is refused, not silently skipped":
    # The third possibility, and the dangerous one: an armed launch that
    # quietly behaves as a dry run would teach an operator that arming
    # is safe.
    var refused = false
    try:
      discard performCloudLaunch(probeSpec(), clmArmed, nil,
        fixedEnvLookup([]))
    except CloudLaunchError as err:
      refused = err.condition == clcArmedLaunchHasNoEffector
    check refused

  test "the effector is handed provider variable NAMES and never values":
    # The effector gets EVERY name, not only the secrets: a launch needs
    # the project and the region as much as it needs the key, and the
    # narrowing that belongs in this build is on what the plan is
    # SEARCHED for, not on what the tool may read.
    let ledger = EffectorLedger()
    let names = providerEnvNamesFor(cpAwsEc2)
    check names.len > 0
    check credentialEnvNamesFor(cpAwsEc2).len < names.len
    var saved: seq[(string, bool, string)] = @[]
    for name in names:
      saved.add (name, existsEnv(name), getEnv(name))
    try:
      for i, name in names:
        putEnv(name, "reproos-sentinel-value-" & $i)
      discard performCloudLaunch(probeSpec(), clmArmed,
        recordingEffector(ledger), fixedEnvLookup([]))
      check ledger.calls == 1
      check ledger.lastEnvNames == names
      let everything = (ledger.lastArgv & ledger.lastEnvNames).join(" ")
      for i, _ in names:
        check ("reproos-sentinel-value-" & $i) notin everything
    finally:
      for row in saved:
        if row[1]: putEnv(row[0], row[2]) else: delEnv(row[0])
    # The restore happened, so nothing after this case is measuring a
    # polluted environment.
    for row in saved:
      check existsEnv(row[0]) == row[1]

  test "this gate does not read the developer's own environment":
    # Both of this build's first two credential-check faults were
    # invisible to a gate that happened to run with the variables
    # unset, and were a hard refusal on the machine of anyone who had
    # them set. A gate whose result depends on that is not a gate. So
    # every library call above states the environment it means, and
    # this case pins the two ends of it: the plan is the same whatever
    # is exported, and the check still fires when the STATED
    # environment carries a secret.
    let plain = checkedCloudLaunchPlan(probeSpec(), fixedEnvLookup([]))
    let name = credentialEnvNamesFor(cpAwsEc2)[0]
    let saved = getEnv(name)
    let had = existsEnv(name)
    try:
      putEnv(name, probeSpec().imageReference)
      check checkedCloudLaunchPlan(probeSpec(), fixedEnvLookup([])) ==
        plain
      # THE MISSING HALF, added by review. The line above says a stated
      # environment gives the same answer whatever is exported. On its
      # own that is satisfied by a build in which nothing ever reads the
      # process environment at all — which would make the title true for
      # the wrong reason — and it is also satisfied while OTHER calls in
      # this same file quietly read it, which is what was happening:
      # two of them did, and the gate was 17/2 and exit 1 under this
      # very export until they were repaired.
      #
      # So the ambient read is exercised rather than assumed: the SAME
      # call with no environment stated refuses, here, now, with this
      # variable set. That is what makes stating one a decision.
      var ambientRefused = false
      try:
        discard checkedCloudLaunchPlan(probeSpec())
      except CloudLaunchError as err:
        ambientRefused =
          err.condition == clcLaunchPlanCarriesCredentialMaterial
      check ambientRefused
    finally:
      if had: putEnv(name, saved) else: delEnv(name)
    # …and with that variable put back, an unstated call is fine again —
    # but only when NO declared secret is set, because any one of them
    # is enough to refuse. Guarding on the single variable this case
    # exported is not enough, and getting that wrong is how review's
    # first draft of this line failed while running under a DIFFERENT
    # variable's export.
    var anySecretSet = false
    for other in allCredentialEnvNames():
      if getEnv(other).len >= MinSecretValueLen: anySecretSet = true
    if not anySecretSet:
      check checkedCloudLaunchPlan(probeSpec()) == plain
    var refused = false
    try:
      discard checkedCloudLaunchPlan(probeSpec(),
        fixedEnvLookup([(name, probeSpec().imageReference)]))
    except CloudLaunchError as err:
      refused = err.condition == clcLaunchPlanCarriesCredentialMaterial
    check refused

suite "the process: nothing was started":

  test "the shim instrument fires when a shim is run":
    # The control, FIRST, so everything below it is a measurement rather
    # than an assumption. A shim that could never run would make every
    # "no invocation" line in this file vacuous.
    installShims()
    check shimInvocations() == 0
    let savedPath = getEnv("PATH")
    try:
      putEnv("PATH", shimDir & ":" & savedPath)
      check execShellCmd("aws ec2 describe-instances") == 0
    finally:
      putEnv("PATH", savedPath)
    check shimInvocations() == 1
    check "ec2 describe-instances" in readFile(shimRecord)
    removeFile(shimRecord)
    check shimInvocations() == 0

  test "neither the library dry run nor the command starts one":
    let savedPath = getEnv("PATH")
    try:
      putEnv("PATH", shimDir & ":" & savedPath)
      let ledger = EffectorLedger()
      # The environment is STATED here too. Found by review, running
      # this gate with one credential variable exported whose value a
      # probe plan legitimately spells: this call and the one in the
      # socket case next door were the two in this file that still read
      # the process environment, and 19 passing cases became 17 with 2
      # failures and exit 1 — the same fault the change closed at the
      # COMMAND, surviving in two direct library calls.
      discard performCloudLaunch(probeSpec(), clmDryRun,
        recordingEffector(ledger), fixedEnvLookup([]))
      check ledger.calls == 0
      check runAttestCommandIn(launchArgs()) == AttestExitAccepted
    finally:
      putEnv("PATH", savedPath)
    check shimInvocations() == 0

suite "the socket: none was opened":

  test "the counter reports ABSENCE rather than zero where it cannot look":
    # The instrument's own honesty, exercised on every platform: a
    # directory that does not exist is not a process with no sockets.
    check socketFdCount(scratch / "no-such-directory") == -1

  test "no descriptor of this process became a socket":
    let before = socketFdCount(ProcFdRoot)
    if before < 0:
      # This platform does not publish the instrument's source. The
      # case then asserts THAT, rather than asserting a number it did
      # not measure — see the case above, which reaches this same arm
      # of `socketFdCount` on every platform.
      check socketFdCount(ProcFdRoot) == -1
      checkpoint("no per-process descriptor directory on this platform")
    else:
      # The control: the counter must be able to move.
      let probe = newSocket()
      let withSocket = socketFdCount(ProcFdRoot)
      check withSocket == before + 1
      probe.close()
      check socketFdCount(ProcFdRoot) == before
      # And now the measurement, against a STATED environment — see the
      # note in the process case above.
      let ledger = EffectorLedger()
      discard performCloudLaunch(probeSpec(), clmDryRun,
        recordingEffector(ledger), fixedEnvLookup([]))
      check runAttestCommandIn(launchArgs()) == AttestExitAccepted
      check socketFdCount(ProcFdRoot) == before

suite "the filesystem: only what was asked for":

  test "a dry run writes nothing, and --out writes exactly one file":
    let observed = scratchDir("filesystem-out")
    check entriesOf(observed).len == 0
    check runAttestCommandIn(launchArgs()) == AttestExitAccepted
    check entriesOf(observed).len == 0
    # The control: the same command, asked to write, writes one file —
    # and it is the manifest, not a receipt for anything created.
    let outPath = observed / "reproos.attested-image.json"
    check runAttestCommandIn(launchArgs() & @["--out", outPath]) ==
      AttestExitAccepted
    check entriesOf(observed) == @["reproos.attested-image.json"]
    let parsed = parseAttestedImageManifest(readFile(outPath), outPath)
    check parsed.sevSnp.len == 1
    # The command and the library agree about the launch, byte for byte.
    check DigestPrefix & sha256Hex(readFile(outPath)) ==
      cloudLaunchIdentity(probeSpec())
    check readFile(outPath) == cloudExpectedManifestText(probeSpec())

suite "the command line cannot ask for a launch":

  test "every spelling of arming is an unknown flag":
    # Not "is ignored". An ignored flag is how an operator comes to
    # believe a command did something it did not.
    var refusedFlags = 0
    for flag in ["--armed", "--apply", "--execute", "--no-dry-run",
                 "--yes", "--force", "--run", "--create"]:
      let outcome = runCapturing(launchArgs() & @[flag])
      check outcome.code == AttestExitUsage
      check ("unknown `repro attest` flag: " & flag) in outcome.err
      inc refusedFlags
    check refusedFlags == 8
    # And the same invocation WITHOUT any of them is accepted, so the
    # refusals above are about the flag and not about the rest of it.
    check runAttestCommandIn(launchArgs()) == AttestExitAccepted

  test "the command describes the launch it was ASKED for":
    # The hole this closes was found by mutating the command rather than
    # the library, and it is the shape the gate beside this one is
    # written against, displaced one layer: the only cross-check between the
    # command and the library anywhere above is the MANIFEST, and a
    # manifest is by construction insensitive to every OPERATIONAL
    # parameter — which is exactly the set that reaches the provider
    # invocation. So a command that answered `--region` with a constant
    # rendered `--region us-west-2` for `--region us-east-1`, PRINTED
    # that plan five times into this gate's own output, and passed
    # every case.
    #
    # The probe needs no reading of standard output. Each parameter that
    # reaches a command line is given, one at a time, a value the
    # LIBRARY refuses, and the command is required to refuse: a command
    # that dropped the flag or answered it with a constant renders a
    # valid plan and exits 0.
    #
    # Its limit, stated rather than left to be discovered: this catches
    # a parameter SUBSTITUTED or ignored. A flag dropped so that the
    # field is left empty is refused too, by the required-parameter rule
    # — a different rule reaching the same exit code — so that shape is
    # covered by accident here and not by design.
    const RefusedEverywhere = "not a legal value"
    var probed = 0
    for flag in ["--region", "--instance-name", "--instance-shape",
                 "--image-reference", "--subnet", "--ssh-key-reference"]:
      let base = launchArgs()
      var args: seq[string] = @[]
      var i = 0
      var replaced = 0
      while i < base.len:
        if base[i] == flag:
          args.add base[i]
          args.add RefusedEverywhere
          inc replaced
          i += 2
        else:
          args.add base[i]
          inc i
      checkpoint(flag)
      # The probe reached the invocation it meant to, so a flag renamed
      # out from under this list is red rather than silently unprobed.
      check replaced == 1
      check args.len == base.len
      check runAttestCommandIn(args) == AttestExitUsage
      inc probed
    # …and the set probed is the set the library says reaches a command
    # line, so a parameter added to that set without a probe is red.
    var reaching = 0
    for p in CloudLaunchParameter:
      if reachesTheCommandLine(p): inc reaching
    check probed == reaching
    check probed == 6

suite "the command line still cannot launch anything":

  test "the armed path has exactly one caller, and it is the leased one":
    # This case used to assert that NOTHING under `libs` or `apps`
    # called the procedure that launches. That was true and it was the
    # reason the whole teardown substrate was a library property rather
    # than a product one: the release, the handlers and the sweep had no
    # caller either, so an armed launch written later would have created
    # an instance with none of them on.
    #
    # The claim is therefore an ACCOUNTING now, not a zero. There is
    # exactly ONE caller of the armed path in the shipped tree, it is
    # the leased launch, and that procedure refuses to create anything
    # outside a `withCloudLease` scope. A second caller appearing
    # anywhere is red; so is the one caller disappearing.
    const Holder = "repro_attest/cloud_lease.nim"
    var scanned = 0
    var holderFiles = 0
    var holderSites = 0
    var elsewhereSites = 0
    var armedMentions = 0
    for root in ["libs", "apps"]:
      for path in nimSourcesUnder(repoRoot / root):
        inc scanned
        let sites = occurrencesIn(path, "performCloudLaunch(")
        if path.endsWith(Holder):
          inc holderFiles
          # ONE site, and it is the call. The declaration is next door
          # in `cloud_launch.nim` and is spelled with a `*` before the
          # parenthesis, so this needle does not match it — which is
          # why the number here is one and not two.
          holderSites += sites
        else:
          elsewhereSites += sites
        if path.endsWith("cloud_launch.nim") or path.endsWith(Holder):
          continue
        armedMentions += occurrencesIn(path, "clmArmed")
    # The instrument's floor: a walk that found almost nothing would
    # satisfy every count by having nothing to disagree with them.
    check scanned > 1000
    check holderFiles == 1
    check holderSites == 1
    check elsewhereSites == 0
    # And the mode is still named nowhere else — in particular, nowhere
    # in the command-line surface.
    check armedMentions == 0

  test "no command-line surface can reach the armed path":
    # The claim that survives the change above, and the one an operator
    # cares about: there is no flag that launches. The leased launch is
    # reachable from a library caller that supplies an effector, and
    # this build's command supplies none and names neither procedure.
    let cli = repoRoot / "libs/repro_cli_support/src/repro_cli_support/attest.nim"
    check fileExists(cli)
    check occurrencesIn(cli, "performCloudLaunch(") == 0
    check occurrencesIn(cli, "performLeasedCloudLaunch(") == 0
    check occurrencesIn(cli, "clmArmed") == 0
    # The control: the same reader over the same file finds the sweep,
    # which this build DOES drive from the command line — so the three
    # zeroes are measurements and not a path that reads nothing.
    check occurrencesIn(cli, "reapCloudLeases(") == 1

  test "the OTHER way to create one is accounted for too":
    # The accounting above is over ONE spelling. Handing an effector the
    # invocation directly — `effector(CloudEffect(argv: leasedLaunchPlan
    # (…)))` — creates an instance without going near the procedure that
    # refuses outside a lease scope, and the gates' own child helper
    # does exactly that. So the renderers that PRODUCE a create
    # invocation are counted as well, and a new consumer of one under
    # `libs` or `apps` is red until somebody says why it is there.
    #
    # This does not make the guard total: a caller could inline the
    # argument vector. What it removes is the cheap way past it, which
    # is the one a next agent writing an armed launch would reach for.
    var renderers = 0
    var consumers: seq[string] = @[]
    for root in ["libs", "apps"]:
      for path in nimSourcesUnder(repoRoot / root):
        let sites = occurrencesIn(path, "leasedLaunchPlan(") +
                    occurrencesIn(path, "cloudLaunchPlan(")
        if sites == 0: continue
        renderers += sites
        consumers.add path.extractFilename
    consumers.sort()
    # `cloud_launch.nim` renders it once, inside the checked wrapper;
    # `cloud_lease.nim` rewrites that output once and hands it to the
    # armed path; the command renders it once to PRINT it and never
    # hands it to anything. Three files, one site each, and each one is
    # named — the declarations do not count, because a `*` sits between
    # the name and the parenthesis this needle ends with.
    check consumers == @["attest.nim", "cloud_launch.nim",
                         "cloud_lease.nim"]
    check renderers == 3
    # The control: the same reader, over a needle that occurs nowhere,
    # returns nothing — so the enumeration above is a measurement.
    var absentSites = 0
    for root in ["libs", "apps"]:
      for path in nimSourcesUnder(repoRoot / root):
        absentSites += occurrencesIn(path,
          "leasedLaunchPlan" & "NoSuch" & "Renderer(")
    check absentSites == 0

  test "the scanner finds both in a file that has both":
    # The negative control. Run against THIS file, which calls the
    # procedure and names the mode, the same scanner must return
    # non-zero — so the two zeroes above are measurements.
    let self = currentSourcePath()
    check occurrencesIn(self, "performCloudLaunch(") >= 4
    check occurrencesIn(self, "clmArmed") >= 3
    # …and it is a SUBSTRING count over bytes, so a needle that occurs
    # nowhere returns zero from the same reader that returns non-zero
    # above. Without this, a scanner that always returned zero would
    # satisfy every line of the previous case.
    # The needle is ASSEMBLED at run time. Written as one literal it
    # would occur in this very file and the count would be one — which
    # is how the first draft of this line failed, and is worth leaving
    # recorded: a scanner pointed at its own source counts itself.
    let absent = "performCloudLaunch" & "NoSuch" & "Procedure("
    check occurrencesIn(self, absent) == 0

  test "the module the adapter is built on does not reach the driver seam":
    # A known defect lives behind that seam: a read error on a report
    # attribute escapes it as an `IOError` rather than as a refusal,
    # on a path only a machine with a root of trust reaches. This
    # adapter launches nothing and must not be the thing that hits it,
    # so the claim is made mechanically rather than by reading the
    # imports: the adapter's module closure is walked and required not
    # to contain the seam or either backend built on it.
    let libRoot = repoRoot / "libs"
    let entry = libRoot / "repro_attest/src/repro_attest/cloud_launch.nim"
    check fileExists(entry)
    let closure = moduleClosure(libRoot, entry)
    check closure.len >= 4
    for forbidden in ["driver.nim", "tsm_report.nim", "snp_backend.nim",
                      "tdx_backend.nim"]:
      var reached = false
      for path in closure:
        if path.endsWith("/" & forbidden): reached = true
      if reached:
        checkpoint("the adapter's closure reaches " & forbidden)
      check not reached
    # The control: the walk DOES find the seam from a module that is
    # built on it, so the absences above are measurements.
    let backend = libRoot / "repro_attest/src/repro_attest/snp_backend.nim"
    var seamReached = false
    for path in moduleClosure(libRoot, backend):
      if path.endsWith("/tsm_report.nim"): seamReached = true
    check seamReached

suite "teardown":

  test "the scratch directory is removed":
    removeDir(scratch)
    check not dirExists(scratch)
