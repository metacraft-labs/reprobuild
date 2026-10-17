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
##   repro attest cross-check --manifest PATH --policy PATH
##       --attestations PATH [--signer-key PATH]...
##       [--signer-admission <key-id>=<from>/<until>]...
##       [--witnessed-root <log-id>:<size>:<root>]...
##       --uki PATH --verity-image-digest sha256:<hex>
##       --verity-root-hash <hex> --config-fingerprint TOKEN [--out PATH]
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
## `cross-check` is about the manifest rather than about a machine. It
## takes a published manifest and the rebuilder signatures that vouch
## for it, computes the manifest HERE from the image, and compares the
## two field by field. The two sides are produced by different work —
## one arrived as signed bytes somebody else computed, the other is
## arithmetic performed now over the image's own bytes — and that is
## the whole value of the command. What it shares with itself is the
## INPUTS, and the report says so in its own last line.
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

import std/[options, os, sequtils, strutils, tables, times]

import cbor

import repro_attest
import repro_attest/cloud_lease
import repro_attest/cose
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
    ascCrossCheck
      ## Compare a measurement manifest somebody else published against
      ## one computed here from the image.
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
    attestationsPath*: string
    signerKeyPaths*: seq[string]
    signerAdmissions*: seq[string]
    revokedSigners*: seq[string]
    vendorRevocationListPaths*: seq[string]
    witnessedRoots*: seq[string]
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
    reapDestroy*: bool
    reapTagSweep*: bool
    reapInterval*: string
    reapSweeps*: string

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
    aecAcceptedEvidenceBackedManifest = 5
      ## An acceptance whose established identity was read out of a
      ## measurement manifest the policy pinned nothing about, and which
      ## a quorum of the rebuilders the policy admits had signed.
      ##
      ## Its own code rather than ``0`` or ``4``. It is not ``0``
      ## because the operator's own list of manifest digests did not
      ## decide it; it is not ``4`` because something DID vouch for the
      ## document, and a script that treated "a named quorum signed
      ## this" the same as "nobody vouched for this" could not express
      ## the posture the evidence clause exists to offer.
      ##
      ## Appended, so no existing ordinal moves.

const
  AttestExitAccepted* = ord(aecAccepted)
  AttestExitRejected* = ord(aecRejected)
  AttestExitUsage* = ord(aecUsage)
  AttestExitAcceptedNoRootOfTrust* = ord(aecAcceptedNoRootOfTrust)
  AttestExitAcceptedUnauthenticatedManifest* =
    ord(aecAcceptedUnauthenticatedManifest)
  AttestExitAcceptedEvidenceBackedManifest* =
    ord(aecAcceptedEvidenceBackedManifest)

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
  of vdAcceptedEvidenceBackedManifest: aecAcceptedEvidenceBackedManifest
  of vdRejected: aecRejected

proc renderAttestUsage*(): string =
  result = """usage: repro attest <subcommand> [options]

Subcommands:
  expect     compute the measurement manifest for an attested image
  challenge  mint a verifier nonce and record when it was minted
  verify     check a runtime report against a measurement policy
  cross-check
             judge one measurement manifest from both directions — the
             document a quorum of admitted rebuilders signed, and one
             computed here from the image — and compare them field by
             field. Exit 1 on any divergence, naming every field that
             moved. It compares the COMPUTATION: both sides are handed
             the same image, so agreement says nothing about whether
             that image is the right one.
  reap       sweep a cloud-lease store. By default it REPORTS: every
             lease it can see, whether its owner is alive, whether it
             has expired, what it has cost so far, and the invocation
             each one would be destroyed with, touching nothing. With
             --destroy it runs those invocations, which is what bounds
             how long a leaked instance can keep billing.
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

repro attest cross-check --manifest PATH --policy PATH
                         --attestations PATH [options]
      --manifest PATH               the measurement manifest somebody
                                    else published, which the
                                    attestations are about
      --attestations PATH           the reproos.edge-attestations.v1
                                    bundle that vouches for it
      --policy PATH                 the measurement policy whose
                                    [measurements.evidence] clause says
                                    how many rebuilder signatures are
                                    needed and whose count
      --signer-key PATH             a COSE_Key for one admitted
                                    rebuilder; repeatable
      --signer-admission SPEC       <key-id>=<from>/<until>; required for
                                    every --signer-key
      --revoked-signer SPEC         <key-id>=<instant>:<reason>
      --witnessed-root SPEC         <log-id>:<tree-size>:<root-hash>
      --uki PATH                    the unified kernel image the local
                                    side measures (or --image, as for
                                    `expect`)
      --verity-image-digest DIGEST  sha256:<hex> of the integrity-
                                    protected root image
      --verity-root-hash HEX        the dm-verity root hash
      --config-fingerprint TOKEN    the configuration the local side
                                    computes for. NOT read out of the
                                    document under test: a field taken
                                    from there would be compared against
                                    itself
      --out PATH                    write the comparison report here
                                    instead of to standard output

      Every `expect` flag that names an image input is accepted here and
      means the same thing.

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
      --attestations PATH           the edge attestations published beside
                                    the manifest: rebuilder signatures over
                                    the claim that this configuration
                                    produces it, and any transparency-log
                                    inclusion proofs for that claim
      --signer-key PATH             a COSE_Key holding one admitted
                                    rebuilder's public key; repeatable. The
                                    policy says which key identifiers may
                                    count; this says what their keys are,
                                    and the two sets must agree exactly.
      --signer-admission KID=FROM/UNTIL
                                    for how long that key counts, as two
                                    instants written YYYY-MM-DDTHH:MM:SSZ;
                                    repeatable and REQUIRED for every
                                    --signer-key. There is no spelling for
                                    a key admitted forever: a key that
                                    outlives its holder's control is what
                                    an operator ends up with by leaving a
                                    field alone. Rotate by OVERLAP — open
                                    the successor's window before the
                                    predecessor's closes.
      --revoked-signer KID=AT:WHY   that key stops counting from that
                                    instant; repeatable. A revocation is
                                    applied at verification time and a
                                    quorum signature carries no signing
                                    time, so this withdraws every bundle
                                    the key contributed to.
      --vendor-revocation-list PATH a DER revocation list from a
                                    confidential-computing vendor's own
                                    distribution service; repeatable. A
                                    DIFFERENT document from
                                    --revocation-list — signed by a vendor
                                    root rather than by an operator anchor
                                    — and without it every bundled vendor
                                    chain is refused for having no
                                    revocation data.
      --witnessed-root LOG:SIZE:HEX a transparency-log root this verifier
                                    has already witnessed; repeatable. An
                                    inclusion proof for a log with no
                                    witnessed root here is refused, because
                                    a proof checked against a root the same
                                    document supplied establishes nothing.
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

repro attest reap --lease-store DIR [options]
      --lease-store DIR             the lease store to sweep
      --now UNIX                    the moment to judge expiry against
      --destroy                     really destroy what the sweep
                                    selects, by running the provider's
                                    own tool. Without it the sweep is
                                    printed and nothing is touched.
      --tag-sweep                   sweep by provider tag instead of by
                                    the store, for a sweeper that has
                                    lost the records or never had them.
                                    Needs --provider and --region, reaps
                                    on expiry only, and implies --destroy
      --interval-seconds N          repeat the sweep every N seconds
                                    (default """ & $DefaultReapIntervalSeconds &
    """, at most """ & $MaxReapIntervalSeconds & """). A leaked
                                    instance outlives its owner by at
                                    most its remaining hold plus this.
      --sweeps N                    stop after N sweeps. Omitted, the
                                    sweep runs ONCE, unless
                                    --interval-seconds asked for a
                                    cadence, in which case it repeats
                                    until it is stopped

Exit codes:
  0  success, or a verdict of `accepted`
  1  a --check mismatch, a verdict of `rejected`, or a runtime failure
  2  a usage error or a refusal
  3  a verdict of `accepted-without-a-root-of-trust`
  4  a verdict of `accepted-against-an-unauthenticated-manifest`: it
     established an identity, out of a manifest your policy pins nothing
     about
  5  a verdict of `accepted-against-an-evidence-backed-manifest`: it
     established an identity, out of a manifest your policy pins nothing
     about and a quorum of the rebuilders it admits had signed
"""

proc fileBytes(path: string): seq[byte] =
  ## A file's bytes. The CBOR reader wants bytes and `readFile` gives a
  ## string; the conversion lives here so it has one spelling.
  let text = readFile(path)
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = byte(text[i])

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
  of "cross-check": result.sub = ascCrossCheck
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
    of "--attestations":
      result.attestationsPath = valueFor(args, i, "--attestations")
    of "--signer-key":
      result.signerKeyPaths.add valueFor(args, i, "--signer-key")
    of "--signer-admission":
      result.signerAdmissions.add valueFor(args, i, "--signer-admission")
    of "--revoked-signer":
      result.revokedSigners.add valueFor(args, i, "--revoked-signer")
    of "--vendor-revocation-list":
      result.vendorRevocationListPaths.add(
        valueFor(args, i, "--vendor-revocation-list"))
    of "--witnessed-root":
      result.witnessedRoots.add valueFor(args, i, "--witnessed-root")
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
    of "--destroy":
      result.reapDestroy = true
      inc i
    of "--tag-sweep":
      result.reapTagSweep = true
      inc i
    of "--interval-seconds":
      result.reapInterval = valueFor(args, i, "--interval-seconds")
    of "--sweeps": result.reapSweeps = valueFor(args, i, "--sweeps")
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

type
  LocalManifestOutcome = object
    ## The manifest this build computes from an image, or the exit code
    ## it refused with.
    ##
    ## `code` is zero exactly when `manifest` and `text` were filled in,
    ## so a caller cannot read a manifest out of a refusal.
    manifest: AttestedImageManifest
    text: string
    uki: string
      ## Which unified kernel image the measurements were taken over,
      ## after `--image`'s conventional names have been resolved. A
      ## report that did not name it would not say what was measured.
    code: int

proc computeManifestLocally(opts: AttestCliOptions;
                            verb: string): LocalManifestOutcome =
  ## Resolve the image inputs the caller named and compute the
  ## measurement manifest for them, or refuse and say why.
  ##
  ## Factored out of `expect` when a second subcommand needed the same
  ## answer. There is therefore ONE route from image bytes to a
  ## manifest in this CLI, which is the property the "rebuild it
  ## locally and compare" posture rests on: a second route would be a
  ## second opinion about what an image measures, and the comparison
  ## would then be between two of this build's own opinions rather than
  ## between a published document and the image.
  ##
  ## `verb` prefixes every refusal, because the reader of these is
  ## whoever typed the command and the command they typed differs.
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
      stderr.writeLine(verb & ": --image " & opts.image &
        " is neither a directory nor a file")
      return LocalManifestOutcome(code: AttestExitUsage)
  if ukiPath.len == 0:
    stderr.writeLine(verb & ": no unified kernel image; " &
      "pass --image <dir-or-uki> or --uki <path>")
    return LocalManifestOutcome(code: AttestExitUsage)
  if not fileExists(ukiPath):
    stderr.writeLine(verb & ": no unified kernel image at " & ukiPath)
    return LocalManifestOutcome(code: AttestExitUsage)

  var verityDigest = opts.verityImageDigest
  if verityDigest.len == 0:
    if verityImagePath.len == 0:
      stderr.writeLine(verb & ": no integrity-protected root " &
        "image; pass --verity-image <path> or --verity-image-digest " &
        "sha256:<hex>. An attested image's identity covers its root " &
        "filesystem, so a manifest without it would describe something else.")
      return LocalManifestOutcome(code: AttestExitUsage)
    if not fileExists(verityImagePath):
      stderr.writeLine(verb & ": no integrity-protected root " &
        "image at " & verityImagePath)
      return LocalManifestOutcome(code: AttestExitUsage)
    verityDigest = DigestPrefix & sha256Hex(readFile(verityImagePath))

  var rootHash = opts.verityRootHash
  if rootHash.len == 0:
    if rootHashFile.len == 0:
      stderr.writeLine(verb & ": no dm-verity root hash; pass " &
        "--verity-root-hash <hex> or --verity-root-hash-file <path>")
      return LocalManifestOutcome(code: AttestExitUsage)
    if not fileExists(rootHashFile):
      stderr.writeLine(verb & ": no root-hash file at " & rootHashFile)
      return LocalManifestOutcome(code: AttestExitUsage)
    rootHash = readFile(rootHashFile).strip()

  if opts.configFingerprint.len == 0:
    stderr.writeLine(verb & ": --config-fingerprint is required; " &
      "a manifest that does not say which configuration it describes cannot " &
      "be matched to one")
    return LocalManifestOutcome(code: AttestExitUsage)

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
        stderr.writeLine(verb & ": " & flag[0] & " describes a " &
          "confidential launch and no --firmware was given, so nothing " &
          "would be measured with it")
        return LocalManifestOutcome(code: AttestExitUsage)
    if opts.hasSnpCmdline:
      stderr.writeLine(verb & ": --launch-cmdline describes a " &
        "confidential launch and no --firmware was given, so nothing would " &
        "be measured with it")
      return LocalManifestOutcome(code: AttestExitUsage)
  else:
    if not fileExists(opts.firmware):
      stderr.writeLine(verb & ": no firmware image at " &
        opts.firmware)
      return LocalManifestOutcome(code: AttestExitUsage)
    var inputs = SevSnpLaunchInputs(firmware: readFile(opts.firmware))
    for flag in [("--vcpus", opts.vcpus), ("--vcpu-type", opts.vcpuType),
                 ("--guest-policy", opts.guestPolicy),
                 ("--guest-features", opts.guestFeatures),
                 ("--vmm", opts.vmm)]:
      if flag[1].len == 0:
        stderr.writeLine(verb & ": --firmware computes a " &
          "confidential-launch expectation and " & flag[0] & " is required " &
          "with it; a launch measurement computed from a default is a " &
          "number no machine will report")
        return LocalManifestOutcome(code: AttestExitUsage)
    try:
      inputs.vcpus = parseInt(opts.vcpus)
    except ValueError:
      stderr.writeLine(verb & ": --vcpus is not a number: " &
        opts.vcpus)
      return LocalManifestOutcome(code: AttestExitUsage)
    inputs.vcpuType = opts.vcpuType
    for flag in [("--guest-policy", opts.guestPolicy),
                 ("--guest-features", opts.guestFeatures)]:
      if not flag[1].startsWith("0x"):
        stderr.writeLine(verb & ": " & flag[0] &
          " must be written as 0x<hex>, got " & flag[1])
        return LocalManifestOutcome(code: AttestExitUsage)
    try:
      inputs.guestPolicy = uint64(parseHexInt(opts.guestPolicy))
      inputs.guestFeatures = uint64(parseHexInt(opts.guestFeatures))
    except ValueError:
      stderr.writeLine(verb & ": --guest-policy and " &
        "--guest-features must be hexadecimal")
      return LocalManifestOutcome(code: AttestExitUsage)
    if opts.snpKernel.len > 0:
      if not fileExists(opts.snpKernel):
        stderr.writeLine(verb & ": no kernel at " & opts.snpKernel)
        return LocalManifestOutcome(code: AttestExitUsage)
      inputs.measuresKernel = true
      inputs.kernel = readFile(opts.snpKernel)
      if opts.snpInitrd.len > 0:
        if not fileExists(opts.snpInitrd):
          stderr.writeLine(verb & ": no initial ramdisk at " &
            opts.snpInitrd)
          return LocalManifestOutcome(code: AttestExitUsage)
        inputs.initrd = readFile(opts.snpInitrd)
      inputs.cmdline = opts.snpCmdline
    elif opts.snpInitrd.len > 0 or opts.hasSnpCmdline:
      stderr.writeLine(verb & ": --launch-initrd and " &
        "--launch-cmdline are measured as part of a directly booted " &
        "kernel's digests, and no --launch-kernel was given")
      return LocalManifestOutcome(code: AttestExitUsage)
    try:
      inputs.vmm = vmmKindFor(opts.vmm)
    except SnpLaunchError as err:
      stderr.writeLine(verb & ": --vmm: " & err.msg)
      return LocalManifestOutcome(code: AttestExitUsage)
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
        stderr.writeLine(verb & ": " & flag[0] & " describes a " &
          "trust-domain launch and no --td-firmware was given, so nothing " &
          "would be measured with it")
        return LocalManifestOutcome(code: AttestExitUsage)
  else:
    if not fileExists(opts.tdxFirmware):
      stderr.writeLine(verb & ": no trust-domain firmware image " &
        "at " & opts.tdxFirmware)
      return LocalManifestOutcome(code: AttestExitUsage)
    if opts.tdxRegisterLog.len == 0:
      stderr.writeLine(verb & ": --td-firmware computes a " &
        "trust-domain expectation and --td-register-log is required with " &
        "it; the three runtime registers are replayed from a log and " &
        "cannot be derived from an image")
      return LocalManifestOutcome(code: AttestExitUsage)
    if not fileExists(opts.tdxRegisterLog):
      stderr.writeLine(verb & ": no event log at " &
        opts.tdxRegisterLog)
      return LocalManifestOutcome(code: AttestExitUsage)
    if opts.tdxPageOrder.len == 0:
      stderr.writeLine(verb & ": --td-firmware computes a " &
        "trust-domain expectation and --td-page-order is required with " &
        "it; both orders occur on real hosts and they give different " &
        "measurements, so a default would be a number no machine reports")
      return LocalManifestOutcome(code: AttestExitUsage)
    var order: TdxHostOrder
    try:
      order = tdxHostOrderFor(opts.tdxPageOrder)
    except TdxLaunchError as err:
      stderr.writeLine(verb & ": --td-page-order: " & err.msg)
      return LocalManifestOutcome(code: AttestExitUsage)
    tdxLaunches.add TdxLaunchInputs(
      firmware: readFile(opts.tdxFirmware),
      registerLog: readFile(opts.tdxRegisterLog),
      order: order)

  result.uki = ukiPath
  try:
    let manifest = attestedImageManifest(opts.configFingerprint,
      readFile(ukiPath), verityDigest, rootHash, backends, launches,
      tdxLaunches)
    result.manifest = manifest
    result.text = renderAttestedImageManifest(manifest)
  except ManifestError as err:
    stderr.writeLine(verb & ": " & err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)
  except SnpLaunchError as err:
    stderr.writeLine(verb & ": " & opts.firmware & ": " & err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)
  except TdxLaunchError as err:
    stderr.writeLine(verb & ": " & opts.tdxFirmware & ": " &
      err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)
  except TcgEventLogError as err:
    stderr.writeLine(verb & ": " & opts.tdxRegisterLog & ": " &
      err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)
  except MeasurementError as err:
    stderr.writeLine(verb & ": " & ukiPath & ": " & err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)

  # The document is re-read through the strict parser before it leaves.
  # Emitting a document this build could not itself accept is the one
  # failure mode a measurement manifest must not have.
  try:
    let reparsed = parseAttestedImageManifest(result.text, "<computed>")
    if renderAttestedImageManifest(reparsed) != result.text:
      stderr.writeLine(verb & ": the computed manifest does not " &
        "round-trip through its own parser; refusing to emit it")
      return LocalManifestOutcome(code: AttestExitUsage)
  except CatchableError as err:
    stderr.writeLine(verb & ": the computed manifest is not " &
      "acceptable to this build's own parser: " & err.msg)
    return LocalManifestOutcome(code: AttestExitUsage)

proc runAttestExpect(opts: AttestCliOptions): int =
  let local = computeManifestLocally(opts, "repro attest expect")
  if local.code != 0: return local.code
  let text = local.text

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

proc runAttestLaunch(opts: AttestCliOptions; env: CloudEnvLookup): int =
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
      plan = leasedLaunchPlan(spec, holder.lease, env)
      scan = requirePlanCarriesNoCredential(plan, env)
    else:
      let checked = checkedCloudLaunchPlanScanned(spec, env)
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
# Two modes, and the difference between them is the difference between
# a substrate and a safety property.
#
# Without `--destroy` this prints the decision for every lease it can
# see and the invocation each one would be destroyed with, and touches
# nothing — which is the right default for a command that destroys
# machines.
#
# With `--destroy` it runs them, through the effector this build ships.
# That is the half that was missing: the reaper answers the one exit
# path the holder cannot see, a printing reaper answers it with a
# sentence, and a leak whose destroy is "until somebody runs the sweep"
# has no bound at all. `--interval-seconds` is the other half — a sweep
# that runs once is not a cadence — and it is capped, because the
# interval is the term that turns the exposure window into a number.
# ---------------------------------------------------------------------

proc runAttestReap(opts: AttestCliOptions; env: CloudEnvLookup): int =
  let destroying = opts.reapDestroy or opts.reapTagSweep
  if opts.reapTagSweep:
    if opts.provider.len == 0 or opts.region.len == 0:
      stderr.writeLine("repro attest reap: --tag-sweep needs --provider " &
        "and --region; a sweep that reads no store has nothing else to " &
        "say which cloud and which region it means")
      return AttestExitUsage
  elif opts.leaseStore.len == 0:
    stderr.writeLine("repro attest reap: --lease-store is required; a " &
      "sweep with no store named would either scan nothing or scan " &
      "somewhere nobody asked for")
    return AttestExitUsage
  elif not dirExists(opts.leaseStore):
    stderr.writeLine("repro attest reap: no lease store at " &
      opts.leaseStore)
    return AttestExitUsage

  var stated = 0'i64
  var hasStated = false
  if opts.leaseNow.len > 0:
    try:
      stated = parseBiggestInt(opts.leaseNow)
      hasStated = true
    except ValueError:
      stderr.writeLine("repro attest reap: --now is " &
        opts.leaseNow.escape() & " and it is read as whole seconds")
      return AttestExitUsage

  var interval = DefaultReapIntervalSeconds
  if opts.reapInterval.len > 0:
    try:
      interval = parseBiggestInt(opts.reapInterval)
    except ValueError:
      stderr.writeLine("repro attest reap: --interval-seconds is " &
        opts.reapInterval.escape() & " and it is read as whole seconds")
      return AttestExitUsage
    if interval <= 0 or interval > MaxReapIntervalSeconds:
      stderr.writeLine("repro attest reap: --interval-seconds is " &
        $interval & " and this build sweeps at least once every " &
        $MaxReapIntervalSeconds & " seconds; the interval is half of " &
        "how long a leaked instance can keep billing, so a longer one " &
        "is not a preference this command accepts")
      return AttestExitUsage

  # ONE sweep unless a cadence was asked for. Repetition is what
  # `--interval-seconds` means, and tying it to that flag rather than to
  # `--destroy` is a correction the gate found: written the other way a
  # bare `repro attest reap --destroy` never returned, which is a
  # surprise on a command line and is not what a `oneshot` unit wants
  # either. `--sweeps` overrides both, and zero is refused because a
  # sweep that never runs is not a sweep.
  var sweeps = 1
  if opts.reapInterval.len > 0: sweeps = 0    # until it is stopped
  if opts.reapSweeps.len > 0:
    try:
      sweeps = parseBiggestInt(opts.reapSweeps)
    except ValueError:
      stderr.writeLine("repro attest reap: --sweeps is " &
        opts.reapSweeps.escape() & " and it is read as a whole number")
      return AttestExitUsage
    if sweeps <= 0:
      stderr.writeLine("repro attest reap: --sweeps is " & $sweeps &
        " and a sweep that never runs is not a sweep")
      return AttestExitUsage

  var provider: CloudProvider
  if opts.reapTagSweep:
    try:
      provider = cloudProviderFor(opts.provider)
    except CloudLaunchError as err:
      stderr.writeLine("repro attest reap: " & err.msg)
      return AttestExitUsage

  # The destroying effector, wrapped so the command can SAY which
  # program it resolved and from where. This is a PATH-resolved external
  # tool — nothing here provisioned it and nothing afterwards can say
  # which file it was — so the resolution is reported rather than left
  # implicit. An operator whose instances have just been destroyed is
  # entitled to know by what.
  var resolvedProgram = ""
  var resolvedFrom = ""
  var effector: CloudLeaseEffector = nil
  if destroying:
    let inner = subprocessCloudLeaseEffector(env)
    effector = proc (effect: CloudEffect): CloudEffectResult =
      result = inner(effect)
      if result.program.len > 0 and resolvedProgram.len == 0:
        resolvedProgram = result.program
        resolvedFrom = result.searchPath
        stdout.write("provider-tool: " & resolvedProgram & "\n")
        stdout.write("provider-tool-search-path: " & resolvedFrom & "\n")
  var failures = 0
  var swept = 0
  while sweeps == 0 or swept < sweeps:
    let now = (if hasStated: stated else: getTime().toUnix)
    try:
      if opts.reapTagSweep:
        let report = reapExpiredByTag(provider, opts.region, now, effector)
        stdout.write(renderReapReportText(report))
        failures += report.failed
      elif destroying:
        let report = reapCloudLeases(openCloudLeaseStore(opts.leaseStore),
          now, processOwnerLiveness(), effector)
        stdout.write(renderReapReportText(report))
        failures += report.failed
      else:
        stdout.write(renderReapPlanText(
          openCloudLeaseStore(opts.leaseStore), now,
          processOwnerLiveness()))
    except CloudLeaseError as err:
      stderr.writeLine("repro attest reap: " & err.msg)
      return AttestExitUsage
    except CloudLaunchError as err:
      stderr.writeLine("repro attest reap: " & err.msg)
      return AttestExitUsage
    inc swept
    stdout.flushFile()
    if sweeps == 0 or swept < sweeps:
      sleep(int(interval * 1000))
  # A sweep that could not destroy something is a FAILURE and not a
  # usage error: the record is still there, the next sweep tries again,
  # and whatever runs this on a cadence has to be able to tell the two
  # apart.
  if failures > 0: return AttestExitRejected
  AttestExitAccepted

# ---------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------

proc loadEvidenceInputs(opts: AttestCliOptions; req: var VerificationRequest;
                        verb: string; readVendorLists: bool): int =
  ## The build plane's evidence and the roster it is judged against, read
  ## off the verifier's own disk into `req`. Returns 0, or the exit code
  ## it refused with.
  ##
  ## Shared by the two subcommands that judge a measurement manifest, so
  ## the refusals below — a key with no admission window, a window over a
  ## key nobody supplied, a revocation of a key nobody holds — hold for
  ## both. Written once because an operator who got a different answer
  ## out of two commands over the same files would have no way to tell
  ## which one was lying.
  # The build plane's evidence, and the two things the verifier supplies
  # to judge it with. Every one of them is a REFUSAL when it cannot be
  # read, for the reason stated above the trust store: a verifier that
  # dropped what it could not parse would be judging against a smaller
  # set than the one it was configured with, and would not say so.
  if opts.attestationsPath.len > 0:
    if not fileExists(opts.attestationsPath):
      stderr.writeLine(verb & ": no edge attestations at " &
        opts.attestationsPath)
      return AttestExitUsage
    req.attestationsSource = opts.attestationsPath
    req.attestationsText = some(readFile(opts.attestationsPath))
  if readVendorLists:
    for path in opts.vendorRevocationListPaths:
      # A vendor's list is RAW DER here rather than a parsed record: the
      # two chain evaluators read their own vendor's format, and this
      # field is deliberately the one place both of them are handed
      # everything so each can take its own by issuer name. Before this
      # flag existed nothing populated it, so every bundled vendor chain
      # took the no-revocation-data refusal whatever the operator held.
      if not fileExists(path):
        stderr.writeLine(verb & ": no vendor revocation list at " &
          path)
        return AttestExitUsage
      req.vendorRevocationLists.add readFile(path)
  elif opts.vendorRevocationListPaths.len > 0:
    # A vendor's revocation list judges a RUNTIME certificate chain, and
    # this caller is judging none. Refused rather than read and ignored:
    # a flag that does nothing is a lie about what was checked.
    stderr.writeLine(verb & ": --vendor-revocation-list judges a " &
      "runtime certificate chain and this command judges none, so it " &
      "would be read and thrown away")
    return AttestExitUsage
  var admissionOf = initTable[string, (int64, int64)]()
  for spec in opts.signerAdmissions:
    let eq = spec.find('=')
    let slash = (if eq < 0: -1 else: spec.find('/', eq + 1))
    if eq <= 0 or slash < 0:
      stderr.writeLine(verb & ": --signer-admission " &
        spec.escape() & " must be <key-id>=<from>/<until>, each instant " &
        "written " & IssuedAtFormat)
      return AttestExitUsage
    let kid = spec[0 ..< eq].toLowerAscii
    var fromAt, untilAt: int64
    try:
      fromAt = parseIsoInstant(spec[eq + 1 ..< slash],
                               "--signer-admission " & kid & " start")
      untilAt = parseIsoInstant(spec[slash + 1 .. ^1],
                                "--signer-admission " & kid & " end")
    except LifecycleError as err:
      stderr.writeLine(verb & ": " & err.msg)
      return AttestExitUsage
    if admissionOf.hasKey(kid):
      stderr.writeLine(verb & ": --signer-admission names " &
        kid & " twice; two windows for one key would admit it for " &
        "whichever was read last")
      return AttestExitUsage
    admissionOf[kid] = (fromAt, untilAt)
  var revocationOf = initTable[string, (int64, string)]()
  for spec in opts.revokedSigners:
    let eq = spec.find('=')
    let colon = (if eq < 0: -1 else: spec.find(':', eq + 1))
    if eq <= 0 or colon < 0 or colon + 1 >= spec.len:
      stderr.writeLine(verb & ": --revoked-signer " &
        spec.escape() & " must be <key-id>=<instant>:<reason>, the " &
        "instant written " & IssuedAtFormat & " and the reason non-empty")
      return AttestExitUsage
    let kid = spec[0 ..< eq].toLowerAscii
    var at: int64
    try:
      at = parseIsoInstant(spec[eq + 1 ..< colon],
                           "--revoked-signer " & kid & " instant")
    except LifecycleError as err:
      stderr.writeLine(verb & ": " & err.msg)
      return AttestExitUsage
    revocationOf[kid] = (at, spec[colon + 1 .. ^1])
  for path in opts.signerKeyPaths:
    if not fileExists(path):
      stderr.writeLine(verb & ": no signer key at " & path)
      return AttestExitUsage
    var signer: QuorumSigner
    try:
      signer = QuorumSigner(key: parseCoseKey(decodeItem(fileBytes(path))))
    except CatchableError as err:
      stderr.writeLine(verb & ": --signer-key " & path &
        " is not a COSE_Key this build reads: " & err.msg)
      return AttestExitUsage
    let kid = signerNameOf(signer.key)
    if not admissionOf.hasKey(kid):
      stderr.writeLine(verb & ": --signer-key " & path &
        " holds key " & kid & " and no --signer-admission states for how " &
        "long it counts; a key admitted with no window is one nobody " &
        "decided to admit forever")
      return AttestExitUsage
    let (fromAt, untilAt) = admissionOf[kid]
    signer = admittedSigner(signer.key, fromAt, untilAt)
    if revocationOf.hasKey(kid):
      let (at, why) = revocationOf[kid]
      signer = revoked(signer, at, why)
    req.signerRoster.add signer
  for kid in admissionOf.keys:
    if not req.signerRoster.anyIt(signerNameOf(it.key) == kid):
      stderr.writeLine(verb & ": --signer-admission names " &
        kid & " and no --signer-key supplies that key; a window over a " &
        "key this verifier does not hold admits nothing and hides a typo")
      return AttestExitUsage
  for kid in revocationOf.keys:
    if not req.signerRoster.anyIt(signerNameOf(it.key) == kid):
      stderr.writeLine(verb & ": --revoked-signer names " &
        kid & " and no --signer-key supplies that key; a revocation of a " &
        "key this verifier does not hold withdraws nothing, and reads " &
        "like it withdrew something")
      return AttestExitUsage
  for spec in opts.witnessedRoots:
    let parts = spec.split(':')
    if parts.len != 3:
      stderr.writeLine(verb & ": --witnessed-root " &
        spec.escape() & " must be <log-id>:<tree-size>:<root-hash>")
      return AttestExitUsage
    var size = 0
    try:
      size = parseInt(parts[1])
    except ValueError:
      stderr.writeLine(verb & ": --witnessed-root " &
        spec.escape() & " does not state a tree size")
      return AttestExitUsage
    req.witnessedLogRoots.add WitnessedLogRoot(
      logId: parts[0], treeSize: size, rootHash: parts[2])
  0

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

  # The build plane's evidence, and the two things the verifier supplies
  # to judge it with.
  let evidenceCode = loadEvidenceInputs(opts, req, "repro attest verify",
                                        readVendorLists = true)
  if evidenceCode != 0: return evidenceCode

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

# ---------------------------------------------------------------------
# cross-check
#
# Two postures over ONE measurement manifest, and the comparison
# between them.
#
# A verifier can come to hold a measurement manifest two ways. It can
# take a document somebody else published and believe it because a
# quorum of admitted rebuilders signed the claim that this configuration
# produces it. Or it can rebuild the image's expectations itself and
# believe the result because it computed it. Each posture has a failure
# mode the other does not: a signed document is only worth the signer
# set, and a local computation is only worth the inputs it was handed.
#
# This command runs both over one image and compares them FIELD BY
# FIELD. The point is that the two sides are produced by different
# work: the left side's numbers were computed by whoever published the
# document, somewhere else, and arrived here as signed bytes; the right
# side's are computed here, now, from the image's own bytes. Where they
# agree, the published document is corroborated by arithmetic nobody
# who published it performed. Where they disagree, the divergence names
# the expectation that moved — which is the thing an operator has to
# act on, and which "the digests differ" does not say.
#
# What it does NOT establish is written in the usage text and in the
# report it prints, because a cross-check whose limits are not stated
# reads as a stronger claim than it is. In particular the two sides
# share their INPUTS — the same unified kernel image, the same root
# hash, the same configuration fingerprint — so this compares the
# computation, never the inputs. An operator handed the wrong image
# gets agreement about the wrong image.
# ---------------------------------------------------------------------

const
  CrossCheckVerb = "repro attest cross-check"

  CrossCheckAgreed* = "the two postures name the same image"
  CrossCheckDiverged* = "the two postures do NOT name the same image"
    ## The two sentences the report ends with. Exported so a caller that
    ## reads the report does not have to carry its own copy of the
    ## wording, which is how a reader and a writer come to disagree.

  CrossCheckSharedInputCaveat* =
    "both postures were given the same image, the same root hash and " &
    "the same configuration fingerprint, so this compares the " &
    "computation over those inputs and says nothing about whether the " &
    "inputs are the right ones"

proc crossCheckRefusal(msg: string): int =
  stderr.writeLine(CrossCheckVerb & ": " & msg)
  AttestExitUsage

proc outcomeWord(o: CheckOutcome): string =
  case o
  of coPassed: "passed"
  of coFailed: "failed"
  of coSkipped: "skipped"
  of coNotReached: "not-reached"

proc runAttestCrossCheck(opts: AttestCliOptions): int =
  ## Judge one measurement manifest from both directions, compare the
  ## answers field by field, and exit non-zero on any divergence.
  if opts.manifestPath.len == 0:
    return crossCheckRefusal("--manifest is required; it names the " &
      "document somebody else published, which is the whole left-hand " &
      "side of the comparison")
  if opts.policyPath.len == 0:
    return crossCheckRefusal("--policy is required; how many rebuilder " &
      "signatures a manifest needs and whose they may be is the " &
      "operator's decision, and defaulting to one would be this build " &
      "deciding what you trust")
  if opts.attestationsPath.len == 0:
    return crossCheckRefusal("--attestations is required; without them " &
      "the published document is authenticated by nothing, and " &
      "comparing an unauthenticated document against a local rebuild " &
      "establishes only that two files agree")
  if opts.reportFile.len > 0 or opts.reportUrl.len > 0:
    return crossCheckRefusal("--report-file and --report-url name a " &
      "runtime report and this command judges none; what a machine " &
      "reports is `repro attest verify`'s question")
  if opts.checkPath.len > 0:
    return crossCheckRefusal("--check compares two documents byte for " &
      "byte and belongs to `repro attest expect`; this command compares " &
      "the fields of the document --manifest names")
  # Every remaining flag this command cannot honour is REFUSED rather
  # than read and thrown away, for the reason the
  # `--vendor-revocation-list` arm in `loadEvidenceInputs` states: a
  # flag that is accepted and does nothing tells the caller who passed
  # it that nothing went wrong, and a script that asked for a
  # machine-readable rendering and got prose has no way to notice.
  if opts.asJson:
    return crossCheckRefusal("--json renders a machine-readable VERDICT " &
      "and this command produces a field-by-field comparison, for which " &
      "there is no such rendering; a caller that passed the flag and " &
      "got text would have been told nothing went wrong")
  for flag in [("--trust-anchor", opts.trustAnchorPaths.len),
               ("--revocation-list", opts.revocationListPaths.len)]:
    if flag[1] > 0:
      return crossCheckRefusal(flag[0] & " judges a runtime certificate " &
        "chain and this command judges none, so it would be read and " &
        "thrown away")
  for flag in [("--challenge", opts.challengeHex),
               ("--challenge-file", opts.challengeFile),
               ("--challenge-issued-at", opts.challengeIssuedAt)]:
    if flag[1].len > 0:
      return crossCheckRefusal(flag[0] & " binds a runtime report to a " &
        "verifier nonce and this command judges no runtime report, so " &
        "it would be read and thrown away")
  if opts.configFingerprint.len == 0:
    return crossCheckRefusal("--config-fingerprint is required, and it " &
      "is NOT read out of the document under test: a comparison that " &
      "took it from there would be checking that field against itself")
  if not fileExists(opts.manifestPath):
    return crossCheckRefusal("no measurement manifest at " &
      opts.manifestPath)
  if not fileExists(opts.policyPath):
    return crossCheckRefusal("no policy at " & opts.policyPath)

  # The local posture first. Its inputs are the ones an operator gets
  # wrong, and a usage error should arrive before any signature has been
  # checked rather than after.
  let local = computeManifestLocally(opts, CrossCheckVerb)
  if local.code != 0: return local.code

  var req: VerificationRequest
  req.nowMs = int64(epochTime() * 1000.0)
  req.policySource = opts.policyPath
  try:
    req.policy = parseAttestationPolicy(readFile(opts.policyPath),
                                        opts.policyPath)
  except PolicyError as err:
    return crossCheckRefusal(err.msg)
  let publishedText = readFile(opts.manifestPath)
  req.manifestSource = opts.manifestPath
  req.manifestText = some(publishedText)
  let evidenceCode = loadEvidenceInputs(opts, req, CrossCheckVerb,
                                        readVendorLists = false)
  if evidenceCode != 0: return evidenceCode

  # The published document, through the strict parser. A document this
  # build cannot fully honour is not compared and not partly believed:
  # the comparison would be against whichever half parsed.
  var published: AttestedImageManifest
  var publishedParsed = false
  var publishedComplaint = ""
  try:
    published = parseAttestedImageManifest(publishedText, opts.manifestPath)
    publishedParsed = true
  except ManifestError as err:
    publishedComplaint = err.msg
  except MeasurementError as err:
    publishedComplaint = err.msg

  let judged = judgeManifestEvidence(req)
  let quorum = outcomeOf(judged.quorum, judged.required.quorum)
  let inclusion = outcomeOf(judged.inclusion, judged.required.inclusion)
  let evidenceAccepted =
    publishedParsed and quorum == coPassed and inclusion != coFailed

  var comparison: ManifestComparison
  var comparisonComplaint = ""
  if publishedParsed:
    try:
      comparison = diffAttestedImageManifests(published, local.manifest)
    except ManifestError as err:
      comparisonComplaint = err.msg

  # The fields agreeing while the canonical bytes do not would mean this
  # document has something the comparison above does not cover. That is
  # a defect in the comparison rather than in either document, and it is
  # reported as one rather than resolved in favour of the half that
  # looks healthier.
  let publishedCanonical =
    (if publishedParsed: renderAttestedImageManifest(published) else: "")
  let bytesAgree = publishedParsed and publishedCanonical == local.text
  let fieldsAgree = publishedParsed and comparisonComplaint.len == 0 and
                    comparison.divergences.len == 0
  if fieldsAgree and not bytesAgree:
    comparisonComplaint = "every field this build compares agrees and " &
      "the two canonical documents are still different bytes, so the " &
      "comparison does not cover every field of the document it was " &
      "asked about"

  let agreed = evidenceAccepted and comparisonComplaint.len == 0 and
               comparison.divergences.len == 0 and bytesAgree

  var report = ""
  report.add CrossCheckVerb & ": " & AttestedImageSchema & "\n"
  report.add "\n"
  report.add "evidence-backed posture\n"
  report.add "  manifest: " & opts.manifestPath & "\n"
  report.add "  digest: " & manifestDigestOf(publishedText) & "\n"
  if publishedParsed:
    report.add "  document: readable by this build\n"
  else:
    report.add "  document: REFUSED by this build's own parser\n"
    report.add "    " & publishedComplaint & "\n"
  report.add "  " & $vcEvidenceQuorum & ": " & outcomeWord(quorum) & "\n"
  report.add "    " & judged.quorum.detail & "\n"
  report.add "  " & $vcTransparencyLog & ": " & outcomeWord(inclusion) & "\n"
  report.add "    " & judged.inclusion.detail & "\n"
  report.add "  posture: " &
    (if evidenceAccepted: "accepted" else: "rejected") & "\n"
  report.add "\n"
  report.add "locally computed posture\n"
  report.add "  unified kernel image: " & local.uki & "\n"
  report.add "  configuration: " & opts.configFingerprint & "\n"
  report.add "  digest: " & manifestDigestOf(local.text) & "\n"
  report.add "  posture: accepted\n"
  report.add "\n"
  report.add "comparison\n"
  report.add "  fields compared: " & $comparison.compared & "\n"
  report.add "  fields diverged: " & $comparison.divergences.len & "\n"
  for d in comparison.divergences:
    report.add "    " & d.field & "\n"
    report.add "      evidence-backed:   " & d.left & "\n"
    report.add "      locally computed:  " & d.right & "\n"
  if comparisonComplaint.len > 0:
    report.add "  refused: " & comparisonComplaint & "\n"
  report.add "  canonical bytes: " &
    (if bytesAgree: "identical" else: "different") & "\n"
  report.add "\n"
  report.add "verdict: " &
    (if agreed: CrossCheckAgreed else: CrossCheckDiverged) & "\n"
  report.add "caveat: " & CrossCheckSharedInputCaveat & "\n"

  if opts.outPath.len > 0:
    let dir = opts.outPath.parentDir
    if dir.len > 0 and not dirExists(dir): createDir(dir)
    writeFile(opts.outPath, report)
    echo "wrote " & opts.outPath
  else:
    stdout.write(report)
  (if agreed: AttestExitAccepted else: AttestExitRejected)


proc runAttestCommand*(args: seq[string];
                       env: CloudEnvLookup = nil): int =
  ## `env` is the environment the cloud subcommands READ, stated by the
  ## caller.
  ##
  ## The library was made environment-free and its gates state
  ## `fixedEnvLookup` — and every case that went through this procedure
  ## still reached the process environment, so three gates were
  ## statements about the machine they ran on after all: one exported
  ## variable whose value a plan legitimately spells turned 17 passing
  ## cases into 13, 28 into 27 and 40 into 37. Fail-closed, and a gate
  ## that fails on somebody's laptop and not on somebody else's is not a
  ## gate. Omitted, this is the process environment, which is what an
  ## operator means.
  var opts: AttestCliOptions
  try:
    opts = parseAttestArgs(args)
  except ValueError as err:
    stderr.writeLine("repro attest: " & err.msg)
    stderr.write(renderAttestUsage())
    return AttestExitUsage
  let lookup = (if env == nil: processEnvLookup() else: env)
  case opts.sub
  of ascExpect: runAttestExpect(opts)
  of ascVerify: runAttestVerify(opts)
  of ascChallenge: runAttestChallenge(opts)
  of ascLaunch: runAttestLaunch(opts, lookup)
  of ascReap: runAttestReap(opts, lookup)
  of ascCrossCheck: runAttestCrossCheck(opts)
  of ascNone:
    stderr.write(renderAttestUsage())
    AttestExitUsage
