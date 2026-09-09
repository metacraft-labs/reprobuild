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
##
## `expect` computes the ``reproos.attested-image.v1`` measurement
## manifest for an attested image and prints it, writes it, or compares it
## against one that already exists.
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
## ## Refusals
##
## Every refusal is exit 2 and names what was wrong. In particular an
## unknown ``--backend`` is refused rather than ignored: an image must
## never be published with an expectation nobody can compute, and the
## place to stop that is the build.

import std/[os, strutils]

import repro_attest

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

proc renderAttestUsage*(): string =
  result = """usage: repro attest <subcommand> [options]

Subcommands:
  expect   compute the measurement manifest for an attested image

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

Exit codes: 0 success, 1 mismatch or runtime failure, 2 usage or refusal.
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
  else:
    raise newException(ValueError,
      "unknown `repro attest` subcommand: " & args[0])
  var i = 1
  while i < args.len:
    let a = args[i]
    let flag = (if '=' in a: a[0 ..< a.find('=')] else: a)
    case flag
    of "--image": result.image = valueFor(args, i, "--image")
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
  of ascNone:
    stderr.write(renderAttestUsage())
    2
