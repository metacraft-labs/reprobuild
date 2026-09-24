## `repro attest` — the CLI over the attestation library.
##
## The CLI reference's ``repro attest`` page is the surface contract; this
## module is its implementation.
##
## ## Surface
##
##   repro attest expect --image <path> [--uki PATH] [--verity-image PATH]
##       [--verity-image-digest sha256:<hex>] [--verity-root-hash <hex>]
##       [--verity-root-hash-file PATH] [--config-fingerprint TOKEN]
##       [--backend NAME]... [--out PATH] [--check PATH]
##   repro attest challenge [--bytes N] [--hex] [--out PATH]
##   repro attest verify (--report-file PATH | --report-url URL)
##       --policy PATH [--manifest PATH]
##       [--challenge HEX | --challenge-file PATH]
##       [--challenge-issued-at RFC3339] [--json] [--out PATH]
##
## `expect` computes the ``reproos.attested-image.v1`` measurement
## manifest for an attested image and prints it, writes it, or compares it
## against one that already exists.
##
## `challenge` mints a nonce and records when it was minted. `verify`
## checks one runtime report against a measurement policy and prints the
## verdict — every check it performed, and what came of each.
##
## ## Why the build runs this and not a bespoke emitter
##
## The image build emits its manifest by invoking this command. There is
## therefore exactly one implementation of the schema and of every
## calculator, and the "reproduce it locally and compare" verification
## posture runs the same code the publisher ran. A second emitter would be
## a second opinion about what an image measures, which is precisely the
## thing a measurement manifest exists to remove.
##
## ## Where `verify` gets its expected measurements — and where it will
## ## not get them
##
## From ``--manifest``, a document on the verifier's own disk: the one it
## built with ``expect`` (reproduce locally), or the one its operators
## distributed and its policy pins by digest. There is deliberately **no
## flag that fetches a measurement manifest from the machine being
## verified**, and the fetching code carries no function that could.
##
## An attested image cannot carry its manifest inside the filesystem the
## manifest measures — adding it changes the bytes the hash covers — so a
## machine that serves one serves it from outside that integrity
## guarantee. Nothing on that machine authenticates it. Asking the
## suspect for the evidence is not made safe by the evidence being
## conveniently placed, so the verifier does not ask.
##
## What authenticates the manifest is therefore on the verifier's side:
## ``measurements.manifests`` pins its digest, and when the policy pins
## nothing the verdict says so, in the ``manifest-pinned`` row and again
## in its caveats.
##
## ## Refusals
##
## Every refusal is exit 2 and names what was wrong. In particular an
## unknown ``--backend`` is refused rather than ignored: an image must
## never be published with an expectation nobody can compute, and the
## place to stop that is the build.

import std/[options, os, strutils, times]

import repro_attest
import repro_attest/cloud_lease
import repro_attest_verify
import repro_attest_verify/fetch

const
  ## Artifact names an attested image build writes. `--image <dir>` finds
  ## its inputs by these; every one of them can be overridden by an
  ## explicit flag, so nothing here is load-bearing for a caller that
  ## names its files.
  ConventionalUkiName* = "reproos.efi"
  ConventionalVerityImageName* = "reproos-root.verity.img"
  ConventionalVerityRootHashName* = "reproos-root.verity.roothash"
  ConventionalManifestName* = AttestedImageManifestFileName

type
  AttestSubcommand* = enum
    ascExpect
    ascVerify
    ascChallenge
    ascLaunch
    ascReap
    ascNone ## no or unknown subcommand

  AttestCliOptions* = object
    sub*: AttestSubcommand
    image*: string
    uki*: string
    verityImage*: string
    verityImageDigest*: string
    verityRootHash*: string
    verityRootHashFile*: string
    configFingerprint*: string
    backends*: seq[string]
    outPath*: string
    checkPath*: string
    reportFile*: string
    reportUrl*: string
    policyPath*: string
    manifestPath*: string
    challengeHex*: string
    challengeFile*: string
    challengeIssuedAt*: string
    asJson*: bool
    challengeBytes*: int
    hexOnly*: bool
    trustAnchorPaths*: seq[string]
    revocationListPaths*: seq[string]
    firmware*: string
    vcpus*: string
    vcpuType*: string
    guestPolicy*: string
    guestFeatures*: string
    vmm*: string
    snpKernel*: string
    snpInitrd*: string
    snpCmdline*: string
    hasSnpCmdline*: bool
    tdxFirmware*: string
    tdxRegisterLog*: string
    tdxPageOrder*: string
    provider*: string
    region*: string
    instanceName*: string
    instanceShape*: string
    imageReference*: string
    subnet*: string
    sshKeyReference*: string
    leaseStore*: string
    leaseTtlSeconds*: string
    leaseRateMicros*: string
    leaseOut*: string
    planOut*: string
    leaseNow*: string

type
  AttestExitCode* = enum
    ## Every value `repro attest` can exit with, as one enumeration.
    ##
    ## An enumeration rather than loose integers for two reasons. The
    ## mapping from a verdict to a code is a ``case`` over it below, so a
    ## decision that gains a value and no code is a compile error rather
    ## than a fall-through. And the set is *iterable*, which is what lets
    ## a gate assert that every code this command can produce is written
    ## down in the CLI reference — a promise nobody can keep against a
    ## handful of constants, because there is no way to ask how many of
    ## them there are.
    ##
    ## The ordinals are the contract. A caller scripting on one of them
    ## must never find it meaning something else, so values are
    ## **appended** and never reordered.
    aecAccepted = 0
    aecRejected = 1
    aecUsage = 2
    aecAcceptedNoRootOfTrust = 3
      ## Its own code, and not ``0``. A mock-tier report can satisfy every
      ## clause a policy that allowed the mock tier contains, and a shell
      ## script that tested for success would then treat "the documents
      ## agree with each other" as "the machine is what it says it is".
      ## Every acceptance is a non-failure; only one of them is 0.
    aecAcceptedUnauthenticatedManifest = 4
      ## An acceptance whose established identity was read out of a
      ## measurement manifest the policy pinned nothing about. The
      ## verdict has said so in prose since this command shipped, in the
      ## ``manifest-pinned`` row and again in its caveats — and prose is
      ## not a channel ``$?`` can read, so a script could not tell this
      ## apart from a verdict backed by a manifest its operators had
      ## named in advance. Now it can.

const
  AttestExitAccepted* = ord(aecAccepted)
  AttestExitRejected* = ord(aecRejected)
  AttestExitUsage* = ord(aecUsage)
  AttestExitAcceptedNoRootOfTrust* = ord(aecAcceptedNoRootOfTrust)
  AttestExitAcceptedUnauthenticatedManifest* =
    ord(aecAcceptedUnauthenticatedManifest)

proc attestExitCodeFor*(d: VerdictDecision): AttestExitCode =
  ## The single place a verdict becomes an exit code.
  ##
  ## Written as a total function over ``VerdictDecision`` rather than as
  ## an ``if`` at the point of exit, because the two channels a verdict
  ## speaks through — its text and its exit status — came apart once
  ## already: the decision distinguished a hollow acceptance and the exit
  ## status did not. A ``case`` with no ``else`` is how that stays fixed;
  ## a decision value added without a code here does not compile.
  case d
  of vdAccepted: aecAccepted
  of vdAcceptedNoRootOfTrust: aecAcceptedNoRootOfTrust
  of vdAcceptedUnpinnedManifest: aecAcceptedUnauthenticatedManifest
  of vdRejected: aecRejected

proc renderAttestUsage*(): string =
  result = """usage: repro attest <subcommand> [options]

Subcommands:
  expect     compute the measurement manifest for an attested image
  challenge  mint a verifier nonce and record when it was minted
  verify     check a runtime report against a measurement policy
  reap       report what a sweep of a cloud-lease store would destroy:
             every lease it can see, whether its owner is alive, whether
             it has expired, what it has cost so far, and the invocation
             each one would be destroyed with. It destroys nothing.
  launch     describe a confidential-instance launch on a public cloud:
             the provider invocation it would be made with and the
             expected-measurement identity a policy would pin. It
             launches nothing and this build carries nothing that could.

repro attest expect --image <dir-or-uki> [options]
      --image PATH                  the image build's output directory, or
                                    the unified kernel image itself
      --uki PATH                    the unified kernel image (overrides
                                    the one found under --image)
      --verity-image PATH           the integrity-protected root image
      --verity-image-digest DIGEST  sha256:<hex>, instead of --verity-image
      --verity-root-hash HEX        the dm-verity root hash
      --verity-root-hash-file PATH  read the root hash from a file
      --config-fingerprint TOKEN    the recipe's configuration fingerprint
      --backend NAME                compute this backend only; repeatable
                                    (""" & KnownBackends.join(", ") & """)
      --firmware PATH               the confidential-launch firmware image;
                                    supplying it computes the sev-snp
                                    expectation, and requires the five flags
                                    below
      --vcpus N                     how many processors the guest is launched
                                    with
      --vcpu-type NAME              the machine model the hypervisor presents
      --guest-policy 0xHEX          the launch policy the guest is started
                                    under
      --guest-features 0xHEX        the feature word each processor starts with
      --vmm NAME                    the hypervisor that will start it (""" &
    KnownVmms.join(", ") & """)
      --launch-kernel PATH          measure a directly booted kernel
      --launch-initrd PATH          the initial ramdisk beside it
      --launch-cmdline TEXT         the command line beside it
      --td-firmware PATH            the trust-domain firmware image;
                                    supplying it computes the tdx expectation
                                    and requires --td-register-log with it
      --td-register-log PATH        the event log the domain wrote, replayed
                                    into the three runtime registers the
                                    document carries
      --td-page-order NAME          the order the host folds a page's
                                    contents in (""" & tdxHostOrderNames() & """);
                                    both occur in the wild and they give
                                    different measurements
      --out PATH                    write the manifest instead of printing it
      --check PATH                  compare against an existing manifest and
                                    exit 1 if it differs

repro attest challenge [options]
      --bytes N                     nonce size (default """ &
    $ChallengeBytes & """, at least """ & $ChallengeMinBytes & """)
      --hex                         print only the nonce, not the record
      --out PATH                    write the record instead of printing it

repro attest verify --report-file PATH | --report-url URL [options]
      --report-file PATH            the report to verify
      --report-url URL              fetch it from a running agent instead
                                    (plain http:// only)
      --policy PATH                 the measurement policy (required)
      --manifest PATH               the measurement manifest to compare
                                    against. Never fetched from the machine
                                    under verification; see the CLI reference.
      --challenge HEX               the nonce this verifier issued
      --challenge-file PATH         a record from `repro attest challenge`,
                                    which also says when it was issued
      --challenge-issued-at TIME    that instant, as YYYY-MM-DDTHH:MM:SSZ
      --trust-anchor PATH           a DER root certificate this verifier
                                    trusts; repeatable. Never taken from
                                    the report: a machine that could
                                    contribute to the set it is checked
                                    against would be vouching for itself.
      --revocation-list PATH        a DER revocation list this verifier
                                    holds; repeatable. Required for every
                                    issuer in a bundled chain — an
                                    unasked question is not an answer of
                                    no.
      --json                        print the machine-readable verdict
      --out PATH                    write the verdict instead of printing it

repro attest launch --provider NAME --instance-shape NAME [options]
      --provider NAME               the cloud (""" & cloudProviderNames() & """)
      --region NAME                 the region or zone the instance sits in
      --instance-name NAME          what the instance is called
      --instance-shape NAME         the instance shape; it decides the
                                    processor count and which root of trust
                                    the instance attests with
      --image-reference REF         the provider's reference to the disk
                                    image. NOT covered by any launch
                                    measurement here; see the CLI reference.
      --subnet ID                   the network the instance is placed on
      --ssh-key-reference REF       the provider's reference to the operator
                                    public key
      --firmware PATH               the confidential-launch firmware image
      --vcpu-type NAME              the machine model, on a sev-snp shape
      --guest-policy 0xHEX          the launch policy, on a sev-snp shape
      --guest-features 0xHEX        the feature word, on a sev-snp shape
      --td-page-order NAME          the host fold order, on a tdx shape
      --td-register-log PATH        the measurement record, on a tdx shape
      --config-fingerprint TOKEN    the recipe's configuration fingerprint
      --uki PATH                    the unified kernel image
      --verity-image-digest DIGEST  sha256:<hex> of the root image
      --verity-root-hash HEX        the dm-verity root hash
      --out PATH                    write the expected manifest as well as
                                    printing the plan
      --lease-store DIR             hold the launch under a lease whose
                                    record is written in DIR BEFORE the
                                    plan is rendered, and put the lease's
                                    tags on the rendered invocation
      --lease-ttl-seconds N         how long the hold lasts; a hold with
                                    no deadline is refused
      --lease-rate-micros-per-hour N  what an hour of this instance costs.
                                    Omitted, the hold is reported as
                                    unpriced rather than as free
      --lease-out PATH              write the lease record itself
      --plan-out PATH               write the rendered provider invocation,
                                    one argument per line
      --now UNIX                    the moment the lease is taken from,
                                    for a caller that needs a stated one

repro attest reap --lease-store DIR [--now UNIX]
      --lease-store DIR             the lease store to sweep
      --now UNIX                    the moment to judge expiry against

Exit codes:
  0  success, or a verdict of `accepted`
  1  a --check mismatch, a verdict of `rejected`, or a runtime failure
  2  a usage error or a refusal
  3  a verdict of `accepted-without-a-root-of-trust`
  4  a verdict of `accepted-against-an-unauthenticated-manifest`: it
     established an identity, out of a manifest your policy pins nothing
     about
"""

proc valueFor(args: openArray[string]; i: var int; flag: string): string =
  ## Accepts both ``--flag VALUE`` and ``--flag=VALUE``.
  let a = args[i]
  if a.len > flag.len and a.startsWith(flag & "="):
    inc i
    return a[flag.len + 1 .. ^1]
  if i + 1 >= args.len:
    raise newException(ValueError, flag & " requires a value")
  result = args[i + 1]
  i += 2

proc parseAttestArgs*(args: seq[string]): AttestCliOptions =
  ## Hand-rolled so every unknown flag is a refusal rather than a default.
  if args.len == 0:
    result.sub = ascNone
    return
  case args[0]
  of "expect": result.sub = ascExpect
  of "verify": result.sub = ascVerify
  of "challenge": result.sub = ascChallenge
  of "launch": result.sub = ascLaunch
  of "reap": result.sub = ascReap
  else:
    raise newException(ValueError,
      "unknown `repro attest` subcommand: " & args[0])
  result.challengeBytes = ChallengeBytes
  var i = 1
  while i < args.len:
    let a = args[i]
    let flag = (if '=' in a: a[0 ..< a.find('=')] else: a)
    case flag
    of "--image": result.image = valueFor(args, i, "--image")
    of "--report-file": result.reportFile = valueFor(args, i, "--report-file")
    of "--report-url": result.reportUrl = valueFor(args, i, "--report-url")
    of "--policy": result.policyPath = valueFor(args, i, "--policy")
    of "--manifest": result.manifestPath = valueFor(args, i, "--manifest")
    of "--challenge": result.challengeHex = valueFor(args, i, "--challenge")
    of "--challenge-file":
      result.challengeFile = valueFor(args, i, "--challenge-file")
    of "--challenge-issued-at":
      result.challengeIssuedAt = valueFor(args, i, "--challenge-issued-at")
    of "--trust-anchor":
      result.trustAnchorPaths.add valueFor(args, i, "--trust-anchor")
    of "--revocation-list":
      result.revocationListPaths.add valueFor(args, i, "--revocation-list")
    of "--json":
      result.asJson = true
      inc i
    of "--hex":
      result.hexOnly = true
      inc i
    of "--bytes":
      let raw = valueFor(args, i, "--bytes")
      try:
        result.challengeBytes = parseInt(raw)
      except ValueError:
        raise newException(ValueError, "--bytes is not a number: " & raw)
    of "--uki": result.uki = valueFor(args, i, "--uki")
    of "--verity-image": result.verityImage = valueFor(args, i, "--verity-image")
    of "--verity-image-digest":
      result.verityImageDigest = valueFor(args, i, "--verity-image-digest")
    of "--verity-root-hash":
      result.verityRootHash = valueFor(args, i, "--verity-root-hash")
    of "--verity-root-hash-file":
      result.verityRootHashFile = valueFor(args, i, "--verity-root-hash-file")
    of "--config-fingerprint":
      result.configFingerprint = valueFor(args, i, "--config-fingerprint")
    of "--backend": result.backends.add valueFor(args, i, "--backend")
    of "--firmware": result.firmware = valueFor(args, i, "--firmware")
    of "--vcpus": result.vcpus = valueFor(args, i, "--vcpus")
    of "--vcpu-type": result.vcpuType = valueFor(args, i, "--vcpu-type")
    of "--guest-policy": result.guestPolicy = valueFor(args, i, "--guest-policy")
    of "--guest-features":
      result.guestFeatures = valueFor(args, i, "--guest-features")
    of "--vmm": result.vmm = valueFor(args, i, "--vmm")
    of "--launch-kernel": result.snpKernel = valueFor(args, i, "--launch-kernel")
    of "--launch-initrd": result.snpInitrd = valueFor(args, i, "--launch-initrd")
    of "--launch-cmdline":
      result.snpCmdline = valueFor(args, i, "--launch-cmdline")
      result.hasSnpCmdline = true
    of "--td-firmware": result.tdxFirmware = valueFor(args, i, "--td-firmware")
    of "--td-register-log":
      result.tdxRegisterLog = valueFor(args, i, "--td-register-log")
    of "--td-page-order":
      result.tdxPageOrder = valueFor(args, i, "--td-page-order")
    of "--provider": result.provider = valueFor(args, i, "--provider")
    of "--region": result.region = valueFor(args, i, "--region")
    of "--instance-name":
      result.instanceName = valueFor(args, i, "--instance-name")
    of "--instance-shape":
      result.instanceShape = valueFor(args, i, "--instance-shape")
    of "--image-reference":
      result.imageReference = valueFor(args, i, "--image-reference")
    of "--subnet": result.subnet = valueFor(args, i, "--subnet")
    of "--ssh-key-reference":
      result.sshKeyReference = valueFor(args, i, "--ssh-key-reference")
    of "--lease-store": result.leaseStore = valueFor(args, i, "--lease-store")
    of "--lease-ttl-seconds":
      result.leaseTtlSeconds = valueFor(args, i, "--lease-ttl-seconds")
    of "--lease-rate-micros-per-hour":
      result.leaseRateMicros =
        valueFor(args, i, "--lease-rate-micros-per-hour")
    of "--lease-out": result.leaseOut = valueFor(args, i, "--lease-out")
    of "--plan-out": result.planOut = valueFor(args, i, "--plan-out")
    of "--now": result.leaseNow = valueFor(args, i, "--now")
    of "--out": result.outPath = valueFor(args, i, "--out")
    of "--check": result.checkPath = valueFor(args, i, "--check")
    else:
      raise newException(ValueError, "unknown `repro attest` flag: " & a)

proc firstDifference(a, b: string): string =
  ## Names WHERE two manifests differ. "they differ" diagnoses nothing
  ## when the document is a thousand characters of hex.
  let la = a.splitLines
  let lb = b.splitLines
  for i in 0 ..< max(la.len, lb.len):
    let x = (if i < la.len: la[i] else: "<absent>")
    let y = (if i < lb.len: lb[i] else: "<absent>")
    if x != y:
      return "line " & $(i + 1) & ":\n  computed: " & x & "\n  on disk:  " & y
  "the two documents differ in trailing bytes only"

proc runAttestExpect(opts: AttestCliOptions): int =
  var ukiPath = opts.uki
  var verityImagePath = opts.verityImage
  var rootHashFile = opts.verityRootHashFile
  if opts.image.len > 0:
    if dirExists(opts.image):
      if ukiPath.len == 0: ukiPath = opts.image / ConventionalUkiName
      if verityImagePath.len == 0 and opts.verityImageDigest.len == 0:
        verityImagePath = opts.image / ConventionalVerityImageName
      if rootHashFile.len == 0 and opts.verityRootHash.len == 0:
        rootHashFile = opts.image / ConventionalVerityRootHashName
    elif fileExists(opts.image):
      if ukiPath.len == 0: ukiPath = opts.image
    else:
      stderr.writeLine("repro attest expect: --image " & opts.image &
        " is neither a directory nor a file")
      return 2
  if ukiPath.len == 0:
    stderr.writeLine("repro attest expect: no unified kernel image; " &
      "pass --image <dir-or-uki> or --uki <path>")
    return 2
  if not fileExists(ukiPath):
    stderr.writeLine("repro attest expect: no unified kernel image at " & ukiPath)
    return 2

  var verityDigest = opts.verityImageDigest
  if verityDigest.len == 0:
    if verityImagePath.len == 0:
      stderr.writeLine("repro attest expect: no integrity-protected root " &
        "image; pass --verity-image <path> or --verity-image-digest " &
        "sha256:<hex>. An attested image's identity covers its root " &
        "filesystem, so a manifest without it would describe something else.")
      return 2
    if not fileExists(verityImagePath):
      stderr.writeLine("repro attest expect: no integrity-protected root " &
        "image at " & verityImagePath)
      return 2
    verityDigest = DigestPrefix & sha256Hex(readFile(verityImagePath))

  var rootHash = opts.verityRootHash
  if rootHash.len == 0:
    if rootHashFile.len == 0:
      stderr.writeLine("repro attest expect: no dm-verity root hash; pass " &
        "--verity-root-hash <hex> or --verity-root-hash-file <path>")
      return 2
    if not fileExists(rootHashFile):
      stderr.writeLine("repro attest expect: no root-hash file at " & rootHashFile)
      return 2
    rootHash = readFile(rootHashFile).strip()

  if opts.configFingerprint.len == 0:
    stderr.writeLine("repro attest expect: --config-fingerprint is required; " &
      "a manifest that does not say which configuration it describes cannot " &
      "be matched to one")
    return 2

  let backends =
    if opts.backends.len > 0: opts.backends
    else: @(KnownBackends)

  # The confidential-launch expectation. It is computed only when the
  # caller names the firmware, because the measurement is a function of
  # the firmware's bytes and of five things no build can infer — how many
  # processors, which machine model, which hypervisor, which feature
  # word, which launch policy. There is no default for any of them: a
  # default would produce a well-formed digest for a machine nobody asked
  # for, and the symptom would arrive months later as an attestation
  # failure with nothing to point at. So naming the firmware requires
  # naming all five, and naming none of them leaves the array empty and
  # visibly so.
  var launches: seq[SevSnpLaunchInputs] = @[]
  if opts.firmware.len == 0:
    for flag in [("--vcpus", opts.vcpus), ("--vcpu-type", opts.vcpuType),
                 ("--guest-policy", opts.guestPolicy),
                 ("--guest-features", opts.guestFeatures),
                 ("--vmm", opts.vmm), ("--launch-kernel", opts.snpKernel),
                 ("--launch-initrd", opts.snpInitrd)]:
      if flag[1].len > 0:
        stderr.writeLine("repro attest expect: " & flag[0] & " describes a " &
          "confidential launch and no --firmware was given, so nothing " &
          "would be measured with it")
        return 2
    if opts.hasSnpCmdline:
      stderr.writeLine("repro attest expect: --launch-cmdline describes a " &
        "confidential launch and no --firmware was given, so nothing would " &
        "be measured with it")
      return 2
  else:
    if not fileExists(opts.firmware):
      stderr.writeLine("repro attest expect: no firmware image at " &
        opts.firmware)
      return 2
    var inputs = SevSnpLaunchInputs(firmware: readFile(opts.firmware))
    for flag in [("--vcpus", opts.vcpus), ("--vcpu-type", opts.vcpuType),
                 ("--guest-policy", opts.guestPolicy),
                 ("--guest-features", opts.guestFeatures),
                 ("--vmm", opts.vmm)]:
      if flag[1].len == 0:
        stderr.writeLine("repro attest expect: --firmware computes a " &
          "confidential-launch expectation and " & flag[0] & " is required " &
          "with it; a launch measurement computed from a default is a " &
          "number no machine will report")
        return 2
    try:
      inputs.vcpus = parseInt(opts.vcpus)
    except ValueError:
      stderr.writeLine("repro attest expect: --vcpus is not a number: " &
        opts.vcpus)
      return 2
    inputs.vcpuType = opts.vcpuType
    for flag in [("--guest-policy", opts.guestPolicy),
                 ("--guest-features", opts.guestFeatures)]:
      if not flag[1].startsWith("0x"):
        stderr.writeLine("repro attest expect: " & flag[0] &
          " must be written as 0x<hex>, got " & flag[1])
        return 2
    try:
      inputs.guestPolicy = uint64(parseHexInt(opts.guestPolicy))
      inputs.guestFeatures = uint64(parseHexInt(opts.guestFeatures))
    except ValueError:
      stderr.writeLine("repro attest expect: --guest-policy and " &
        "--guest-features must be hexadecimal")
      return 2
    if opts.snpKernel.len > 0:
      if not fileExists(opts.snpKernel):
        stderr.writeLine("repro attest expect: no kernel at " & opts.snpKernel)
        return 2
      inputs.measuresKernel = true
      inputs.kernel = readFile(opts.snpKernel)
      if opts.snpInitrd.len > 0:
        if not fileExists(opts.snpInitrd):
          stderr.writeLine("repro attest expect: no initial ramdisk at " &
            opts.snpInitrd)
          return 2
        inputs.initrd = readFile(opts.snpInitrd)
      inputs.cmdline = opts.snpCmdline
    elif opts.snpInitrd.len > 0 or opts.hasSnpCmdline:
      stderr.writeLine("repro attest expect: --launch-initrd and " &
        "--launch-cmdline are measured as part of a directly booted " &
        "kernel's digests, and no --launch-kernel was given")
      return 2
    try:
      inputs.vmm = vmmKindFor(opts.vmm)
    except SnpLaunchError as err:
      stderr.writeLine("repro attest expect: --vmm: " & err.msg)
      return 2
    launches.add inputs

  # The trust-domain expectation. Two inputs, both required together:
  # the initial-memory measurement is a function of the firmware image
  # alone, and the three runtime registers the document carries are a
  # REPLAY of the log a domain wrote. Neither can be defaulted — an
  # absent log would mean publishing three rows of zeroes, which agree
  # with every domain that never extended those registers.
  var tdxLaunches: seq[TdxLaunchInputs] = @[]
  if opts.tdxFirmware.len == 0:
    for flag in [("--td-register-log", opts.tdxRegisterLog),
                 ("--td-page-order", opts.tdxPageOrder)]:
      if flag[1].len > 0:
        stderr.writeLine("repro attest expect: " & flag[0] & " describes a " &
          "trust-domain launch and no --td-firmware was given, so nothing " &
          "would be measured with it")
        return 2
  else:
    if not fileExists(opts.tdxFirmware):
      stderr.writeLine("repro attest expect: no trust-domain firmware image " &
        "at " & opts.tdxFirmware)
      return 2
    if opts.tdxRegisterLog.len == 0:
      stderr.writeLine("repro attest expect: --td-firmware computes a " &
        "trust-domain expectation and --td-register-log is required with " &
        "it; the three runtime registers are replayed from a log and " &
        "cannot be derived from an image")
      return 2
    if not fileExists(opts.tdxRegisterLog):
      stderr.writeLine("repro attest expect: no event log at " &
        opts.tdxRegisterLog)
      return 2
    if opts.tdxPageOrder.len == 0:
      stderr.writeLine("repro attest expect: --td-firmware computes a " &
        "trust-domain expectation and --td-page-order is required with " &
        "it; both orders occur on real hosts and they give different " &
        "measurements, so a default would be a number no machine reports")
      return 2
    var order: TdxHostOrder
    try:
      order = tdxHostOrderFor(opts.tdxPageOrder)
    except TdxLaunchError as err:
      stderr.writeLine("repro attest expect: --td-page-order: " & err.msg)
      return 2
    tdxLaunches.add TdxLaunchInputs(
      firmware: readFile(opts.tdxFirmware),
      registerLog: readFile(opts.tdxRegisterLog),
      order: order)

  var text = ""
  try:
    let manifest = attestedImageManifest(opts.configFingerprint,
      readFile(ukiPath), verityDigest, rootHash, backends, launches,
      tdxLaunches)
    text = renderAttestedImageManifest(manifest)
  except ManifestError as err:
    stderr.writeLine("repro attest expect: " & err.msg)
    return 2
  except SnpLaunchError as err:
    stderr.writeLine("repro attest expect: " & opts.firmware & ": " & err.msg)
    return 2
  except TdxLaunchError as err:
    stderr.writeLine("repro attest expect: " & opts.tdxFirmware & ": " &
      err.msg)
    return 2
  except TcgEventLogError as err:
    stderr.writeLine("repro attest expect: " & opts.tdxRegisterLog & ": " &
      err.msg)
    return 2
  except MeasurementError as err:
    stderr.writeLine("repro attest expect: " & ukiPath & ": " & err.msg)
    return 2

  # The document is re-read through the strict parser before it leaves.
  # Emitting a document this build could not itself accept is the one
  # failure mode a measurement manifest must not have.
  try:
    let reparsed = parseAttestedImageManifest(text, "<computed>")
    if renderAttestedImageManifest(reparsed) != text:
      stderr.writeLine("repro attest expect: the computed manifest does not " &
        "round-trip through its own parser; refusing to emit it")
      return 2
  except CatchableError as err:
    stderr.writeLine("repro attest expect: the computed manifest is not " &
      "acceptable to this build's own parser: " & err.msg)
    return 2

  if opts.checkPath.len > 0:
    if not fileExists(opts.checkPath):
      stderr.writeLine("repro attest expect: --check " & opts.checkPath &
        " does not exist")
      return 1
    let onDisk = readFile(opts.checkPath)
    if onDisk != text:
      stderr.writeLine("repro attest expect: " & opts.checkPath &
        " is not what this image measures.\n" & firstDifference(text, onDisk))
      return 1
    echo opts.checkPath & ": matches the image"
    return 0

  if opts.outPath.len > 0:
    let dir = opts.outPath.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.outPath, text)
    echo "wrote " & opts.outPath
  else:
    stdout.write(text)
  0

# ---------------------------------------------------------------------
# challenge
# ---------------------------------------------------------------------

proc runAttestChallenge(opts: AttestCliOptions): int =
  var minted: MintedChallenge
  try:
    minted = mintChallenge(int64(epochTime() * 1000.0), opts.challengeBytes)
  except ChallengeError as err:
    stderr.writeLine("repro attest challenge: " & err.msg)
    return AttestExitUsage
  let text = (if opts.hexOnly: minted.challengeHex & "\n"
              else: renderChallengeRecord(minted))
  if opts.outPath.len > 0:
    let dir = opts.outPath.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.outPath, text)
    echo "wrote " & opts.outPath
  else:
    stdout.write(text)
  AttestExitAccepted

# ---------------------------------------------------------------------
# launch
#
# There is no effector here, and that is the whole design: this
# subcommand reaches `cloudLaunchPlan`, which takes none and has no
# route to one. `performCloudLaunch` — the procedure that WOULD hand an
# invocation on — is not called from this file, and an armed launch
# needs an effector the caller supplies, which this build does not
# contain. So the command's "it launches nothing" is a property of what
# it can reach rather than of a flag it happens not to pass.
# ---------------------------------------------------------------------

proc readLaunchFileArg(flag, path: string; into: var string): string =
  ## Read a file a launch parameter names, or return the sentence to
  ## refuse with. An empty result means it was read.
  if path.len == 0: return ""
  if not fileExists(path):
    return "repro attest launch: no file at " & path & " for " & flag
  into = readFile(path)
  ""

proc runAttestLaunch(opts: AttestCliOptions): int =
  var spec: CloudLaunchSpec
  if opts.provider.len == 0:
    stderr.writeLine("repro attest launch: --provider is required; this " &
      "build describes launches on " & cloudProviderNames())
    return AttestExitUsage
  try:
    spec.provider = cloudProviderFor(opts.provider)
  except CloudLaunchError as err:
    stderr.writeLine("repro attest launch: " & err.msg)
    return AttestExitUsage

  spec.region = opts.region
  spec.instanceName = opts.instanceName
  spec.instanceShape = opts.instanceShape
  spec.imageReference = opts.imageReference
  spec.subnet = opts.subnet
  spec.sshKeyReference = opts.sshKeyReference
  spec.machineModel = opts.vcpuType
  spec.guestPolicy = opts.guestPolicy
  spec.guestFeatures = opts.guestFeatures
  spec.foldOrder = opts.tdxPageOrder
  spec.configFingerprint = opts.configFingerprint
  spec.verityImageDigest = opts.verityImageDigest
  spec.verityRootHash = opts.verityRootHash

  for pair in [("--firmware", opts.firmware), ("--uki", opts.uki),
               ("--td-register-log", opts.tdxRegisterLog)]:
    var into = ""
    let complaint = readLaunchFileArg(pair[0], pair[1], into)
    if complaint.len > 0:
      stderr.writeLine(complaint)
      return AttestExitUsage
    case pair[0]
    of "--firmware": spec.firmware = into
    of "--uki": spec.ukiImage = into
    else: spec.registerLog = into

  # The lease, minted BEFORE the plan is rendered and written to disk
  # before anything else happens. Nothing is created by this command, so
  # nothing here is at risk — but the ORDER is the contract this command
  # documents, and a command that wrote the record afterwards would be
  # documenting the wrong one.
  var holder: CloudLeaseHolder = nil
  let leaseWanted = opts.leaseStore.len > 0 or opts.leaseOut.len > 0
  var leaseNow = getTime().toUnix
  if opts.leaseNow.len > 0:
    try:
      leaseNow = parseBiggestInt(opts.leaseNow)
    except ValueError:
      stderr.writeLine("repro attest launch: --now is " &
        opts.leaseNow.escape() & " and it is read as whole seconds")
      return AttestExitUsage
  var leaseTtl = DefaultLeaseTtlSeconds
  if opts.leaseTtlSeconds.len > 0:
    try:
      leaseTtl = parseBiggestInt(opts.leaseTtlSeconds)
    except ValueError:
      stderr.writeLine("repro attest launch: --lease-ttl-seconds is " &
        opts.leaseTtlSeconds.escape() & " and it is read as whole seconds")
      return AttestExitUsage
  var leaseRate = 0'i64
  if opts.leaseRateMicros.len > 0:
    try:
      leaseRate = parseBiggestInt(opts.leaseRateMicros)
    except ValueError:
      stderr.writeLine("repro attest launch: " &
        "--lease-rate-micros-per-hour is " & opts.leaseRateMicros.escape() &
        " and it is read as a whole number")
      return AttestExitUsage
  if leaseWanted:
    let root = (if opts.leaseStore.len > 0: opts.leaseStore
                else: opts.leaseOut.parentDir)
    try:
      holder = acquireCloudLease(openCloudLeaseStore(root), spec,
        delayed(initDuration(seconds = int(leaseTtl))), leaseNow, leaseRate)
    except CloudLeaseError as err:
      stderr.writeLine("repro attest launch: " & err.msg)
      return AttestExitUsage
    except CloudLaunchError as err:
      stderr.writeLine("repro attest launch: " & err.msg)
      return AttestExitUsage
    except OSError, IOError:
      stderr.writeLine("repro attest launch: the lease record could not " &
        "be written under " & root)
      return AttestExitUsage

  var plan: seq[string] = @[]
  var manifestText = ""
  var scan: PlanSecretScan
  try:
    if holder != nil:
      plan = leasedLaunchPlan(spec, holder.lease)
      scan = requirePlanCarriesNoCredential(plan)
    else:
      let checked = checkedCloudLaunchPlanScanned(spec)
      plan = checked.plan
      scan = checked.scan
    manifestText = cloudExpectedManifestText(spec)
  except CloudLaunchError as err:
    stderr.writeLine("repro attest launch: " & err.msg)
    return AttestExitUsage
  except SnpLaunchError as err:
    stderr.writeLine("repro attest launch: " & err.msg)
    return AttestExitUsage
  except TdxLaunchError as err:
    stderr.writeLine("repro attest launch: " & err.msg)
    return AttestExitUsage
  except TcgEventLogError as err:
    stderr.writeLine("repro attest launch: " & opts.tdxRegisterLog & ": " &
      err.msg)
    return AttestExitUsage
  except ManifestError as err:
    stderr.writeLine("repro attest launch: " & err.msg)
    return AttestExitUsage

  let warning = renderUnsearchableSecretWarning(scan)
  if warning.len > 0:
    stderr.writeLine("repro attest launch: " & warning)

  var outcome = CloudLaunchOutcome(plan: plan, manifestText: manifestText,
    identity: DigestPrefix & sha256Hex(manifestText), secretScan: scan)
  if opts.outPath.len > 0:
    let dir = opts.outPath.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.outPath, manifestText)
    echo "wrote " & opts.outPath
  if opts.planOut.len > 0:
    # The rendered invocation, written where something can read it.
    # This module's own contract calls a plan "the thing that gets
    # recorded as a fixture", and until now the only way to obtain one
    # was to scrape standard output.
    let dir = opts.planOut.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.planOut, plan.join("\n") & "\n")
    echo "wrote " & opts.planOut
  if holder != nil and opts.leaseOut.len > 0:
    let dir = opts.leaseOut.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.leaseOut, renderCloudLease(holder.lease))
    echo "wrote " & opts.leaseOut
  stdout.write(renderCloudLaunchPlanText(outcome))
  if holder != nil:
    stdout.write("lease-id: " & holder.lease.leaseId & "\n")
    stdout.write("lease-expires-at: " &
      $holder.lease.expiresAtUnix & "\n")
  AttestExitAccepted

# ---------------------------------------------------------------------
# reap
#
# The sweep, and it destroys nothing for the same reason `launch`
# creates nothing: the library's reaper takes an effector, this build
# ships none, and the command does not construct one. What it prints is
# the decision for every lease it can see and the invocation each one
# would be destroyed with.
# ---------------------------------------------------------------------

proc runAttestReap(opts: AttestCliOptions): int =
  if opts.leaseStore.len == 0:
    stderr.writeLine("repro attest reap: --lease-store is required; a " &
      "sweep with no store named would either scan nothing or scan " &
      "somewhere nobody asked for")
    return AttestExitUsage
  if not dirExists(opts.leaseStore):
    stderr.writeLine("repro attest reap: no lease store at " &
      opts.leaseStore)
    return AttestExitUsage
  var now = getTime().toUnix
  if opts.leaseNow.len > 0:
    try:
      now = parseBiggestInt(opts.leaseNow)
    except ValueError:
      stderr.writeLine("repro attest reap: --now is " &
        opts.leaseNow.escape() & " and it is read as whole seconds")
      return AttestExitUsage
  try:
    stdout.write(renderReapPlanText(openCloudLeaseStore(opts.leaseStore),
      now, processOwnerLiveness()))
  except CloudLeaseError as err:
    stderr.writeLine("repro attest reap: " & err.msg)
    return AttestExitUsage
  except CloudLaunchError as err:
    stderr.writeLine("repro attest reap: " & err.msg)
    return AttestExitUsage
  AttestExitAccepted

# ---------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------

proc runAttestVerify(opts: AttestCliOptions): int =
  if opts.reportFile.len == 0 and opts.reportUrl.len == 0:
    stderr.writeLine("repro attest verify: no report; pass --report-file " &
      "<path> or --report-url <url>")
    return AttestExitUsage
  if opts.reportFile.len > 0 and opts.reportUrl.len > 0:
    stderr.writeLine("repro attest verify: --report-file and --report-url " &
      "both name a report, and there is no rule saying which one wins")
    return AttestExitUsage
  if opts.policyPath.len == 0:
    stderr.writeLine("repro attest verify: --policy is required. A verifier " &
      "with no policy has no grounds to accept anything, and defaulting to " &
      "one would be this build deciding what you trust.")
    return AttestExitUsage
  if opts.challengeHex.len > 0 and opts.challengeFile.len > 0:
    stderr.writeLine("repro attest verify: --challenge and --challenge-file " &
      "both name a challenge, and there is no rule saying which one wins")
    return AttestExitUsage

  var req: VerificationRequest
  req.nowMs = int64(epochTime() * 1000.0)

  if not fileExists(opts.policyPath):
    stderr.writeLine("repro attest verify: no policy at " & opts.policyPath)
    return AttestExitUsage
  req.policySource = opts.policyPath
  try:
    req.policy = parseAttestationPolicy(readFile(opts.policyPath),
                                        opts.policyPath)
  except PolicyError as err:
    stderr.writeLine("repro attest verify: " & err.msg)
    return AttestExitUsage

  if opts.reportFile.len > 0:
    if not fileExists(opts.reportFile):
      stderr.writeLine("repro attest verify: no report at " & opts.reportFile)
      return AttestExitUsage
    req.reportSource = opts.reportFile
    req.reportText = readFile(opts.reportFile)
  else:
    req.reportSource = opts.reportUrl
    try:
      req.reportText = httpGet(opts.reportUrl)
    except FetchError as err:
      stderr.writeLine("repro attest verify: " & opts.reportUrl & ": " &
        err.msg)
      return AttestExitRejected

  if opts.manifestPath.len > 0:
    if not fileExists(opts.manifestPath):
      stderr.writeLine("repro attest verify: no measurement manifest at " &
        opts.manifestPath)
      return AttestExitUsage
    req.manifestSource = opts.manifestPath
    req.manifestText = some(readFile(opts.manifestPath))

  # The trust store comes from the verifier's own disk and from nowhere
  # else. A malformed anchor is a REFUSAL rather than an anchor quietly
  # dropped: an operator who names a file believes it will be used, and a
  # verifier that skipped the ones it could not read would be trusting a
  # smaller set than the one it was configured with, silently.
  for path in opts.trustAnchorPaths:
    if not fileExists(path):
      stderr.writeLine("repro attest verify: no trust anchor at " & path)
      return AttestExitUsage
    try:
      req.trustAnchors.add parseCertificateBytes(readFile(path))
    except X509Error as err:
      stderr.writeLine("repro attest verify: --trust-anchor " & path &
        " is not a certificate this build reads: " & err.msg)
      return AttestExitUsage
  for path in opts.revocationListPaths:
    if not fileExists(path):
      stderr.writeLine("repro attest verify: no revocation list at " & path)
      return AttestExitUsage
    try:
      req.revocationLists.add parseCrlBytes(readFile(path))
    except X509Error as err:
      stderr.writeLine("repro attest verify: --revocation-list " & path &
        " is not a revocation list this build reads: " & err.msg)
      return AttestExitUsage

  req.expectedChallengeHex = opts.challengeHex
  if opts.challengeFile.len > 0:
    if not fileExists(opts.challengeFile):
      stderr.writeLine("repro attest verify: no challenge record at " &
        opts.challengeFile)
      return AttestExitUsage
    try:
      let record = parseChallengeRecord(readFile(opts.challengeFile),
                                        opts.challengeFile)
      req.expectedChallengeHex = record.challengeHex
      req.challengeIssuedAtMs = some(parseIssuedAtMs(record.issuedAt))
    except ChallengeError as err:
      stderr.writeLine("repro attest verify: " & err.msg)
      return AttestExitUsage
  if opts.challengeIssuedAt.len > 0:
    try:
      req.challengeIssuedAtMs = some(parseIssuedAtMs(opts.challengeIssuedAt))
    except ChallengeError as err:
      stderr.writeLine("repro attest verify: --challenge-issued-at " &
        err.msg)
      return AttestExitUsage

  var verdict: Verdict
  try:
    verdict = verifyAttestationReport(req)
  except VerdictError as err:
    stderr.writeLine("repro attest verify: " & err.msg)
    return AttestExitRejected

  let text = (if opts.asJson: renderVerdictJson(verdict)
              else: renderVerdictText(verdict))
  if opts.outPath.len > 0:
    let dir = opts.outPath.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.outPath, text)
    echo "wrote " & opts.outPath
  else:
    stdout.write(text)

  # Derived, never decided here: this call site cannot say anything
  # about a verdict that `attestExitCodeFor` does not say.
  ord(attestExitCodeFor(verdict.decision))

proc runAttestCommand*(args: seq[string]): int =
  var opts: AttestCliOptions
  try:
    opts = parseAttestArgs(args)
  except ValueError as err:
    stderr.writeLine("repro attest: " & err.msg)
    stderr.write(renderAttestUsage())
    return AttestExitUsage
  case opts.sub
  of ascExpect: runAttestExpect(opts)
  of ascVerify: runAttestVerify(opts)
  of ascChallenge: runAttestChallenge(opts)
  of ascLaunch: runAttestLaunch(opts)
  of ascReap: runAttestReap(opts)
  of ascNone:
    stderr.write(renderAttestUsage())
    AttestExitUsage
