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

const
  AttestExitAccepted* = 0
  AttestExitRejected* = 1
  AttestExitUsage* = 2
  AttestExitAcceptedNoRootOfTrust* = 3
    ## Its own code, and not ``0``. A mock-tier report can satisfy every
    ## clause a policy that allowed the mock tier contains, and a shell
    ## script that tested for success would then treat "the documents
    ## agree with each other" as "the machine is what it says it is".
    ## Both acceptances are non-failures; only one of them is 0.

proc renderAttestUsage*(): string =
  result = """usage: repro attest <subcommand> [options]

Subcommands:
  expect     compute the measurement manifest for an attested image
  challenge  mint a verifier nonce and record when it was minted
  verify     check a runtime report against a measurement policy

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
      --json                        print the machine-readable verdict
      --out PATH                    write the verdict instead of printing it

Exit codes: 0 success or an accepted verdict, 1 mismatch, a rejected verdict,
or a runtime failure, 2 usage or refusal, 3 a verdict accepted against a tier
with no root of trust.
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

  var text = ""
  try:
    let manifest = attestedImageManifest(opts.configFingerprint,
      readFile(ukiPath), verityDigest, rootHash, backends)
    text = renderAttestedImageManifest(manifest)
  except ManifestError as err:
    stderr.writeLine("repro attest expect: " & err.msg)
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

  case verdict.decision
  of vdAccepted: AttestExitAccepted
  of vdAcceptedNoRootOfTrust: AttestExitAcceptedNoRootOfTrust
  of vdRejected: AttestExitRejected

proc runAttestCommand*(args: seq[string]): int =
  var opts: AttestCliOptions
  try:
    opts = parseAttestArgs(args)
  except ValueError as err:
    stderr.writeLine("repro attest: " & err.msg)
    stderr.write(renderAttestUsage())
    return 2
  case opts.sub
  of ascExpect: runAttestExpect(opts)
  of ascVerify: runAttestVerify(opts)
  of ascChallenge: runAttestChallenge(opts)
  of ascNone:
    stderr.write(renderAttestUsage())
    2
