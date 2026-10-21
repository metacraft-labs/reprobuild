## From an accepted change to a staged generation and a local Remix
## (ReproOS-Agent-Harbor-Integration M5 deliverables 1-3).
##
## Staging takes a workspace whose change the user accepted and produces,
## without touching the active generation:
##
## - the change's package output, built into the INSTALLED store beside the
##   original prefix (the store is append-only; a new prefix replaces
##   nothing);
## - a declarative overlay for it: a signed draft Remix manifest
##   (`spec/Remix-Protocol.md` §"Manifest") whose target is the original
##   package by its interface identity, and whose one patch is the change
##   as a recipe-relative unified diff. The manifest and its patch blob are
##   kept in a local overlay directory, private until the user exports or
##   submits them.
##
## Activation is separate and approval-gated: a `GenerationDriver` switches
## to a generation that uses the staged prefix, the health checks the
## manifest declares are run against the new generation, and a failing check
## rolls back to the generation that was active before, automatically.

import std/[algorithm, json, os, osproc, strutils, tables]

import blake3 except toHex
import repro_remix
import repro_peer_cache/auth as peerAuth
import repro_interface_artifacts
import repro_project_dsl/install_mirror_resolver

import ./[ownership, checkout]

type
  StageError* = object of CatchableError

  InterfaceIdentity* = object
    fingerprint*: Digest32
      ## The project interface fingerprint the recipe's interface artifact
      ## carries (`Project-Interface-Artifacts-And-Import-Modes.md`
      ## §"Interface Identity And Invalidation").
    artifactDigest*: Digest32
      ## BLAKE3 of the interface artifact's bytes.

  StagedChange* = object
    package*: string        ## the recipe name
    baseGeneration*: string
    patch*: string          ## recipe-relative unified diff, `-p1`
    changedPaths*: seq[string]
    prefixRel*: string      ## the change's output, store-relative
    prefixPath*: string
    releaseId*: Digest32
    manifestPath*: string   ## the signed envelope in the overlay directory
    healthChecks*: seq[HealthCheck]

  GenerationDriver* = ref object of RootObj
    ## The generation system a backend activates changes in. A driver
    ## builds a generation that uses a staged change's prefix, makes it
    ## current, and can make an earlier generation current again.

method current*(d: GenerationDriver): string {.base.} = ""
method switchTo*(d: GenerationDriver; change: StagedChange): string {.base.} =
  ## Make current a generation that uses `change.prefixPath` for
  ## `change.package`; return its id.
  raise newException(StageError, "this host has no generation driver")
method rollbackTo*(d: GenerationDriver; generation: string) {.base.} =
  raise newException(StageError, "this host has no generation driver")
method launcherDir*(d: GenerationDriver): string {.base.} =
  ## Where the current generation's command launchers are.
  ""

const
  PatchMediaType* = "text/x-diff"
  OverlayNamespace* = "local"

proc toDigest(b: openArray[byte]): Digest32 =
  for i in 0 ..< 32:
    result[i] = b[i]

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s:
    result[i] = byte(ord(c))

proc hexOf(d: Digest32): string = toHex(d)

proc recipeRelativePatch*(diff, recipeName: string): string =
  ## Rewrite a workspace diff (paths `a/<recipe>/…`) into one relative to the
  ## recipe directory (`a/…`), refusing a change to anything outside the
  ## recipe. The result is validated by the Remix patch reader, so a change
  ## v1 patches cannot carry — a created, deleted, renamed or binary file —
  ## is refused here, at staging, with the reader's reason.
  let pre = recipeName & "/"
  for line in diff.splitLines(keepEol = true):
    var l = line
    if l.startsWith("diff --git a/"):
      let body = l["diff --git ".len .. ^1]
      let parts = body.strip(leading = false).split(' ')
      if parts.len != 2 or not parts[0].startsWith("a/" & pre) or
          not parts[1].startsWith("b/" & pre):
        raise newException(StageError, "the change edits a path outside " &
          "the recipe: " & body.strip)
      l = "diff --git a/" & parts[0][2 + pre.len .. ^1] & " b/" &
          parts[1][2 + pre.len .. ^1] & "\n"
    elif l.startsWith("--- a/" & pre):
      l = "--- a/" & l[("--- a/" & pre).len .. ^1]
    elif l.startsWith("+++ b/" & pre):
      l = "+++ b/" & l[("+++ b/" & pre).len .. ^1]
    elif l.startsWith("--- ") or l.startsWith("+++ "):
      raise newException(StageError, "the change edits a path outside " &
        "the recipe: " & l.strip)
    result.add l
  if result.len == 0:
    raise newException(StageError, "there is no change to stage")
  try:
    discard parseUnifiedDiff(result, 1)
  except RemixError as e:
    raise newException(StageError, "the change cannot be a v1 Remix patch: " &
      e.msg)

proc interfaceIdentityFromGraphJson*(graphJson: string): InterfaceIdentity =
  ## Read the interface artifact `repro graph --format=json` names.
  let node =
    try: parseJson(graphJson)
    except JsonParsingError, ValueError:
      raise newException(StageError, "repro graph did not print JSON")
  let path = node{"interfacePath"}.getStr("")
  if path.len == 0 or not fileExists(path):
    raise newException(StageError, "repro graph named no interface artifact")
  let artifact = readInterfaceArtifact(path)
  result.fingerprint = toDigest(artifact.interfaceFingerprint.bytes)
  result.artifactDigest = toDigest(blake3.digest(readFile(path)))

proc slug(s: string): string =
  for c in s.toLowerAscii:
    result.add(if c in {'a'..'z', '0'..'9', '.', '_', '-'}: c else: '-')
  if result.len == 0 or result[0] notin {'a'..'z', '0'..'9'}:
    result = "x" & result

proc draftManifest*(rec: OwnershipRecord; identity: InterfaceIdentity;
                    patch, intent: string; platform: string;
                    healthChecks: seq[HealthCheck];
                    author: KeyId): Manifest =
  ## The declarative overlay of one accepted change: the original package
  ## by its interface identity, the change as one patch, the checks that
  ## decide whether the activated generation is healthy, no permission
  ## change, and the local author. A Remix of original software has no
  ## parents.
  let blob = BlobRef(id: blobId(bytesOf(patch)), mediaType: PatchMediaType,
                     size: uint64(patch.len))
  var checks = healthChecks
  checks.sort(proc (a, b: HealthCheck): int =
    result = cmp(ord(a.kind), ord(b.kind))
    if result == 0: result = cmp(a.target, b.target))
  Manifest(
    remixName: OverlayNamespace & "/" & slug(rec.recipeName),
    version: "0.0.0-local." & hexOf(blob.id)[0 ..< 12],
    intent: intent,
    license: "LicenseRef-Local-Change",
    targets: @[Target(original: OriginalRef(package: rec.recipeName,
      interfaceFingerprint: identity.fingerprint,
      catalogWorkspace: OverlayNamespace,
      catalogRemote: "file:" & slug(rec.catalogRoot.extractFilename),
      catalogRevision: rec.recipeTreeDigest,
      catalogInterfaceArtifact: identity.artifactDigest),
      constraintKind: ckExactFingerprint)],
    platforms: @[platform],
    patches: @[Patch(appliesToKind: ptTarget, appliesToIndex: 0, blob: blob,
                     strip: 1, order: 0)],
    healthChecks: checks,
    authors: @[Digest32(author)])

proc writeOverlay*(overlayRoot: string; m: Manifest; patch: string;
                   key: PeerKeypair): tuple[releaseId: Digest32; path: string] =
  ## Validate, sign and store the manifest and its patch blob under
  ## `overlayRoot/<release id>/`.
  validateManifest(m)
  var env = newManifestEnvelope(m)
  signEnvelope(env, key)
  let rid = Digest32(releaseId(env))
  let dir = overlayRoot / hexOf(rid)
  createDir(dir / "blobs")
  writeFile(dir / "blobs" / hexOf(blobId(bytesOf(patch))), patch)
  let bytes = encodeEnvelope(env)
  var s = newString(bytes.len)
  for i, b in bytes: s[i] = char(b)
  writeFile(dir / "manifest.rbsz", s)
  # Read it back through the same path any consumer uses.
  discard decodeAndVerify(bytes)
  (rid, dir / "manifest.rbsz")

proc exportOverlay*(dir: string): seq[byte] =
  ## A detached Remix export bundle of one stored overlay: its manifest
  ## envelope and every blob it references (`Remix-Protocol.md`
  ## §"Export bundle").
  let manifest = bytesOf(readFile(dir / "manifest.rbsz"))
  var entries = @[(bekManifestEnvelope, manifest)]
  for kind, p in walkDir(dir / "blobs"):
    entries.add (bekBlob, bytesOf(readFile(p)))
  writeBundle(entries)

proc parseHealthChecks*(spec: string): seq[HealthCheck] =
  ## `kind:target[:timeout]` entries separated by `;`, for example
  ## `command-exit-zero:greeter:30;path-exists:bin/greeter`.
  for item in spec.split(';'):
    if item.len == 0:
      continue
    let parts = item.split(':')
    if parts.len < 2:
      raise newException(StageError, "health check " & item.escape &
        " is not kind:target[:timeout]")
    var kind: HealthCheckKind
    var known = false
    for k in HealthCheckKind:
      let name = case k
        of hcUnitActive: "unit-active"
        of hcUnitNotFailed: "unit-not-failed"
        of hcSocketListening: "socket-listening"
        of hcPathExists: "path-exists"
        of hcCommandExitZero: "command-exit-zero"
      if name == parts[0]:
        kind = k
        known = true
    if not known:
      raise newException(StageError, "unknown health check " & parts[0].escape)
    let timeout =
      if parts.len > 2:
        try: uint32(parseInt(parts[2]))
        except ValueError:
          raise newException(StageError, "health check timeout " & parts[2].escape)
      else: 30'u32
    result.add HealthCheck(kind: kind, target: parts[1], timeoutSeconds: timeout)
