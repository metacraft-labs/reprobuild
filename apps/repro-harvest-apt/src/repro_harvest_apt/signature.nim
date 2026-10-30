## C2 P3: GPG signature verification for snapshot.debian.org InRelease.
##
## The apt harvester downloads ``InRelease`` (the clearsigned suite
## metadata) from the snapshot host, extracts the embedded ``Packages``
## SHA-256 + ``Valid-Until`` field, then trusts those bytes to drive a
## ``.deb`` fetch loop. Before any of that trust kicks in, we MUST
## verify the InRelease signature against the vendored Debian archive
## key bundle. This module implements that check.
##
## ## Verification strategy
##
## C2 supports two verification backends, chosen at runtime:
##
##   1. **External GPG** — the preferred backend. We shell out to a
##      ``gpg`` binary on $PATH (or at $REPRO_GPG_BIN), import every
##      ``.gpg`` blob under the key-bundle directory into an ephemeral
##      keyring (never the operator's keyring), then run ``gpg --verify``
##      against the InRelease bytes. This is the same verification path
##      ``apt-secure`` itself uses; it inherits libgcrypt's RSA / EdDSA
##      / SHA-2 implementations for free.
##
##   2. **Vendored fingerprint allowlist (fallback)** — when no ``gpg``
##      is available, we cannot verify the OpenPGP signature itself,
##      but we CAN refuse to proceed unless the InRelease bytes hash to
##      one of the fingerprints listed in the
##      ``MANIFEST.txt`` allowlist. The operator vendors the allowlist
##      alongside the key bundle. This downgrades the threat model from
##      "trust whoever holds the archive key" to "trust whoever signs
##      the vendored manifest", which is still acceptable for a
##      hermetic + audit-friendly workflow but is NOT a substitute for
##      the full PGP verification.
##
## The ``verifyInRelease`` entry point picks the backend automatically
## (external GPG wins when available) and surfaces a structured error
## describing which backend was used + why it rejected the bytes.
##
## ## What is verified
##
## The InRelease file is a single text file beginning with
## ``-----BEGIN PGP SIGNED MESSAGE-----`` and ending with
## ``-----END PGP SIGNATURE-----``. The signed payload (Hashes: section
## with SHA-256 per file in the suite) lives between the
## ``-----BEGIN PGP SIGNED MESSAGE-----`` marker and the
## ``-----BEGIN PGP SIGNATURE-----`` marker.
##
## Our verifier:
##
##   1. Extracts the signed payload + the signature block.
##   2. Runs the chosen backend.
##   3. On success, returns ``InReleaseVerification`` carrying the
##      payload bytes (the caller hashes the suite's ``Packages.xz``
##      etc. against the lines in this payload).
##
## See ``recipes/catalog/foreign/apt/keys/README.md`` for the threat
## model + key-bundle policy.

import std/[os, osproc, strtabs, strutils, tempfiles, times]

import blake3

type
  SignatureBackend* = enum
    sbExternalGpg = "external-gpg"
    sbFingerprintAllowlist = "fingerprint-allowlist"

  InReleaseVerification* = object
    ## Result of a successful verification.
    backend*: SignatureBackend
    payload*: string                 ## the signed-message body (between
                                     ## the ``BEGIN PGP SIGNED MESSAGE``
                                     ## and ``BEGIN PGP SIGNATURE``
                                     ## markers, with the ``Hash:``
                                     ## header stripped); the caller
                                     ## parses this for ``SHA256:`` lines
    signerKeyId*: string             ## opaque identifier (the
                                     ## fingerprint substring gpg --verify
                                     ## logs, or the matched manifest
                                     ## entry id)
    backendLog*: string              ## raw backend log (for diagnostics)

  SignatureVerificationError* = object of CatchableError
    backend*: SignatureBackend
    backendLog*: string

# ---------------------------------------------------------------------------
# Key-bundle discovery
# ---------------------------------------------------------------------------

proc resolveKeyBundleDir*(explicit = ""): string =
  ## Resolve the directory holding the vendored ``.gpg`` key blobs +
  ## the ``MANIFEST.txt`` fingerprint allowlist.
  ##
  ## Precedence:
  ##   1. ``explicit`` argument (CLI ``--gpg-keys``).
  ##   2. ``$REPRO_APT_KEY_BUNDLE`` environment variable.
  ##   3. ``recipes/catalog/foreign/apt/keys/`` resolved from the
  ##      reprobuild repo root via the harvester binary's location.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_APT_KEY_BUNDLE")
  if fromEnv.len > 0:
    return fromEnv
  # Walk up from the harvester's own location, looking for
  # recipes/catalog/foreign/apt/keys.
  var dir = getAppDir()
  for _ in 0 .. 6:
    let candidate = dir / "recipes" / "catalog" / "foreign" / "apt" /
      "keys"
    if dirExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  # Last-resort default: a path that will fail with a clear error.
  "recipes/catalog/foreign/apt/keys"

# ---------------------------------------------------------------------------
# InRelease payload extraction
# ---------------------------------------------------------------------------

proc extractClearsignedPayload*(inRelease: string): tuple[
    payload: string; signature: string] =
  ## Slice an OpenPGP clearsigned message into its signed body + its
  ## ASCII-armored signature block. Both are returned as plain strings
  ## (no normalisation; the backend re-feeds the original bytes
  ## verbatim).
  const BeginMsg = "-----BEGIN PGP SIGNED MESSAGE-----"
  const BeginSig = "-----BEGIN PGP SIGNATURE-----"
  const EndSig = "-----END PGP SIGNATURE-----"

  let beginIdx = inRelease.find(BeginMsg)
  if beginIdx < 0:
    raise newException(SignatureVerificationError,
      "InRelease does not begin with '-----BEGIN PGP SIGNED MESSAGE-----'")
  let sigIdx = inRelease.find(BeginSig, start = beginIdx + 1)
  if sigIdx < 0:
    raise newException(SignatureVerificationError,
      "InRelease has no '-----BEGIN PGP SIGNATURE-----' marker")
  let endIdx = inRelease.find(EndSig, start = sigIdx + 1)
  if endIdx < 0:
    raise newException(SignatureVerificationError,
      "InRelease has no '-----END PGP SIGNATURE-----' marker")

  # The clearsigned body lives between the BEGIN line + the first blank
  # line (after the Hash: header) and the signature block. RFC 4880
  # specifies "Hash:" headers before a blank line, then the message.
  let bodyStart = inRelease.find('\n', beginIdx) + 1
  # Skip header lines until first blank line.
  var idx = bodyStart
  while idx < sigIdx:
    let lineEnd = inRelease.find('\n', idx)
    if lineEnd < 0 or lineEnd >= sigIdx:
      break
    let line = inRelease[idx ..< lineEnd]
    if line.strip().len == 0:
      idx = lineEnd + 1
      break
    idx = lineEnd + 1
  result.payload = inRelease[idx ..< sigIdx]
  result.signature = inRelease[sigIdx ..< endIdx + EndSig.len]

# ---------------------------------------------------------------------------
# Fingerprint allowlist backend
# ---------------------------------------------------------------------------

type
  AllowlistEntry = object
    id: string
    fingerprintHex: string  ## 64-char lowercase hex blake3 fingerprint
                           ## of the canonical InRelease bytes (we use
                           ## blake3 because it's the already-vendored
                           ## hash; the allowlist is content-addressed
                           ## by these digests)

proc parseAllowlistManifest(text: string): seq[AllowlistEntry] =
  ## Parse ``MANIFEST.txt`` lines of shape:
  ##
  ##     <id> <64-char-hex-fingerprint>
  ##
  ## Blank lines + ``#``-prefixed comments are tolerated. The
  ## fingerprint covers the canonical InRelease BYTES (entire file
  ## including the signature block, so a re-issued InRelease with the
  ## same suite metadata but a different signature counts as a new
  ## entry — the operator vendors fresh manifest lines on each
  ## snapshot rotation).
  result = @[]
  for raw in text.splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    if parts.len < 2:
      continue
    if parts[1].len != 64:
      continue
    var entry = AllowlistEntry(id: parts[0],
      fingerprintHex: parts[1].toLowerAscii())
    result.add(entry)

proc blake3Hex(bytes: string): string =
  let raw = blake3.digest(bytes)
  result = newStringOfCap(64)
  const Hex = "0123456789abcdef"
  for i in 0 ..< 32:
    let b = raw[i].uint8
    result.add(Hex[int(b shr 4)])
    result.add(Hex[int(b and 0x0f)])

proc verifyViaAllowlist*(inRelease: string; keyBundleDir: string):
    InReleaseVerification =
  ## The fallback backend.
  let manifestPath = keyBundleDir / "MANIFEST.txt"
  if not fileExists(manifestPath):
    var e = newException(SignatureVerificationError,
      "no MANIFEST.txt in " & keyBundleDir &
      "; cannot run allowlist verification")
    e.backend = sbFingerprintAllowlist
    e.backendLog = "missing " & manifestPath
    raise e
  let entries = parseAllowlistManifest(readFile(manifestPath))
  if entries.len == 0:
    var e = newException(SignatureVerificationError,
      "MANIFEST.txt at " & manifestPath &
      " has no allowlist entries")
    e.backend = sbFingerprintAllowlist
    e.backendLog = "empty allowlist"
    raise e
  let actual = blake3Hex(inRelease)
  for entry in entries:
    if entry.fingerprintHex == actual:
      # Found a match. Extract the payload so the caller can parse the
      # SHA256 entries even though we didn't run PGP verification.
      let parts = extractClearsignedPayload(inRelease)
      return InReleaseVerification(
        backend: sbFingerprintAllowlist,
        payload: parts.payload,
        signerKeyId: entry.id,
        backendLog: "allowlist hit on fingerprint " & actual)

  var e = newException(SignatureVerificationError,
    "InRelease BLAKE3 fingerprint " & actual &
    " is not in the allowlist at " & manifestPath)
  e.backend = sbFingerprintAllowlist
  e.backendLog = "no allowlist match (expected one of " &
    $entries.len & " fingerprints)"
  raise e

# ---------------------------------------------------------------------------
# External gpg backend
# ---------------------------------------------------------------------------

proc resolveGpgBin*(): string =
  ## Resolve the gpg binary the harvester shells out to.
  let fromEnv = getEnv("REPRO_GPG_BIN")
  if fromEnv.len > 0:
    return fromEnv
  let found = findExe("gpg")
  if found.len > 0:
    return found
  ""

type
  GpgStatusVerdict* = object
    good*: bool          ## GOODSIG and VALIDSIG seen, nothing refusing
    signerKeyId*: string ## the VALIDSIG fingerprint (or GOODSIG key id)
    reason*: string      ## why good is false

const
  GpgRefusingStatuses = ["BADSIG", "ERRSIG", "EXPSIG", "EXPKEYSIG",
                         "REVKEYSIG", "NO_PUBKEY", "KEYEXPIRED",
                         "KEYREVOKED", "NODATA", "UNEXPECTED", "FAILURE"]
    ## Status keywords that mean the bytes are NOT vouched for by a current
    ## key, whatever the exit code. gpg 2.4 exits 0 for a good signature by
    ## an EXPIRED key (EXPKEYSIG with VALIDSIG, and KEYEXPIRED),
    ## and documents the same for a revoked one (REVKEYSIG), so the exit
    ## code alone is a fail-open check. doc/DETAILS in the GnuPG source lists
    ## the keywords.

proc gpgStatusVerdict*(statusOutput: string): GpgStatusVerdict =
  ## Decide from --status-fd lines whether a verification is good:
  ## exactly the GOODSIG + VALIDSIG pair, and none of
  ## GpgRefusingStatuses. A clearsigned file carrying several
  ## signatures (Debian signs trixie with three keys) is good when every
  ## signature is good: one refusing status anywhere refuses the whole.
  var goodSig = ""
  var validSig = ""
  var refusals: seq[string] = @[]
  for line in statusOutput.splitLines:
    if not line.startsWith("[GNUPG:] "): continue
    let parts = line.splitWhitespace()
    if parts.len < 2: continue
    let keyword = parts[1]
    if keyword == "GOODSIG" and parts.len >= 3 and goodSig.len == 0:
      goodSig = parts[2]
    elif keyword == "VALIDSIG" and parts.len >= 3 and validSig.len == 0:
      validSig = parts[2]
    elif keyword in GpgRefusingStatuses:
      refusals.add(line[len("[GNUPG:] ") .. ^1])
  if refusals.len > 0:
    result.reason = refusals.join("; ")
  elif goodSig.len == 0 or validSig.len == 0:
    result.reason = "no GOODSIG + VALIDSIG pair in the status output"
  else:
    result.good = true
    result.signerKeyId = validSig

proc verifyViaExternalGpg*(inRelease: string; keyBundleDir: string;
                           gpgBin: string): InReleaseVerification =
  ## Shell-out backend.
  ## Steps:
  ##   1. Create an ephemeral GNUPGHOME under a TMP directory.
  ##   2. ``gpg --import`` every ``*.gpg`` blob from the key bundle.
  ##   3. ``gpg --verify`` the InRelease bytes (read from a temp file).
  ##   4. Parse the result; on success, slice out the signed payload.
  let tmpHome = createTempDir("apt-harvest-gpg-", "")
  defer:
    try: removeDir(tmpHome)
    except: discard
  # Restrict perms (gpg complains if GNUPGHOME is world-readable, but
  # on Windows the default ACL is fine for our purposes).
  let gpgEnv = newStringTable()
  gpgEnv["GNUPGHOME"] = tmpHome
  # Import keys.
  var importLog = ""
  for kind, path in walkDir(keyBundleDir):
    if kind != pcFile: continue
    if not path.toLowerAscii().endsWith(".gpg"): continue
    let (output, exitCode) = execCmdEx(gpgBin & " --batch --quiet" &
      " --import " & quoteShell(path),
      env = gpgEnv)
    importLog.add("import " & extractFilename(path) & " exit=" &
      $exitCode & "\n" & output & "\n")
    if exitCode != 0:
      var e = newException(SignatureVerificationError,
        "gpg --import failed for " & path)
      e.backend = sbExternalGpg
      e.backendLog = importLog
      raise e
  if importLog.len == 0:
    var e = newException(SignatureVerificationError,
      "no .gpg key blobs in " & keyBundleDir &
      "; cannot run external-gpg verification")
    e.backend = sbExternalGpg
    e.backendLog = "empty key bundle"
    raise e

  # Verify.
  let inRelTmp = tmpHome / "InRelease.bin"
  writeFile(inRelTmp, inRelease)
  let (verifyOut, verifyExit) = execCmdEx(gpgBin & " --batch --quiet" &
    " --status-fd 1 --verify " & quoteShell(inRelTmp),
    env = gpgEnv)
  let fullLog = importLog & "verify exit=" & $verifyExit & "\n" &
    verifyOut
  if verifyExit != 0:
    var e = newException(SignatureVerificationError,
      "gpg --verify rejected the InRelease (exit " & $verifyExit & ")")
    e.backend = sbExternalGpg
    e.backendLog = fullLog
    raise e
  let verdict = gpgStatusVerdict(verifyOut)
  if not verdict.good:
    var e = newException(SignatureVerificationError,
      "gpg --verify did not report a good, valid signature: " &
      verdict.reason)
    e.backend = sbExternalGpg
    e.backendLog = fullLog
    raise e
  let signerId = verdict.signerKeyId

  let parts = extractClearsignedPayload(inRelease)
  result = InReleaseVerification(
    backend: sbExternalGpg,
    payload: parts.payload,
    signerKeyId: signerId,
    backendLog: fullLog)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc verifyInReleaseWithKeyring*(inRelease: string; keyringFile: string):
    InReleaseVerification =
  ## Verify against ONE keyring file — apt's ``Signed-By=`` semantics: the
  ## keys that vouch for this archive are exactly the ones its source
  ## names, and a key vendored for another archive is never consulted.
  ## Requires ``gpg`` (the fingerprint allowlist cannot express a
  ## per-archive key set). ``keyringFile`` is a binary (dearmored) OpenPGP
  ## keyring, the form apt ships under ``/usr/share/keyrings/``.
  if not fileExists(keyringFile):
    var e = newException(SignatureVerificationError,
      "keyring " & keyringFile & " does not exist")
    e.backend = sbExternalGpg
    raise e
  let gpgBin = resolveGpgBin()
  if gpgBin.len == 0:
    var e = newException(SignatureVerificationError,
      "--keyring needs gpg on PATH (or REPRO_GPG_BIN)")
    e.backend = sbExternalGpg
    raise e
  let dir = createTempDir("apt-harvest-keyring-", "")
  defer:
    try: removeDir(dir)
    except CatchableError: discard
  copyFile(keyringFile, dir / "keyring.gpg")
  verifyViaExternalGpg(inRelease, dir, gpgBin)

proc verifyInRelease*(inRelease: string; keyBundleDir: string;
                     preferredBackend = sbExternalGpg):
    InReleaseVerification =
  ## Verify the InRelease bytes against the vendored key bundle.
  ## Picks the external-gpg backend when available; falls back to the
  ## fingerprint allowlist when gpg cannot be located AND a
  ## ``MANIFEST.txt`` exists.
  ##
  ## On any verification failure raises ``SignatureVerificationError``
  ## with the backend used + log attached.
  if preferredBackend == sbExternalGpg:
    let gpgBin = resolveGpgBin()
    if gpgBin.len > 0:
      return verifyViaExternalGpg(inRelease, keyBundleDir, gpgBin)
  # Fall back to allowlist.
  verifyViaAllowlist(inRelease, keyBundleDir)

# ---------------------------------------------------------------------------
# Valid-Until enforcement (anti-replay)
# ---------------------------------------------------------------------------

proc enforceValidUntil*(payload: string; now: DateTime) =
  ## Extract the ``Valid-Until:`` field from a verified InRelease
  ## payload and raise ``SignatureVerificationError`` if ``now`` is
  ## past the deadline, or if the field is present but not in the
  ## ``Thu, 29 Oct 2026 22:23:10 UTC`` form the archive format requires: a
  ## deadline that cannot be read is not a deadline that was checked.
  ## Tolerates the absence of the field (snapshot archives omit it).
  for rawLine in payload.splitLines:
    let line = rawLine.strip()
    if line.startsWith("Valid-Until:"):
      let stamp = line[12 .. ^1].strip()
      var parsed: DateTime
      try:
        parsed = parse(stamp, "ddd, dd MMM yyyy HH:mm:ss 'UTC'", utc())
      except CatchableError:
        var e = newException(SignatureVerificationError,
          "InRelease Valid-Until '" & stamp & "' is not a date this " &
          "verifier can read; refusing rather than skipping the check")
        e.backend = sbExternalGpg
        e.backendLog = "Valid-Until enforcement"
        raise e
      if now > parsed:
        var e = newException(SignatureVerificationError,
          "InRelease is stale: Valid-Until " & stamp &
          " is before " & $now)
        e.backend = sbExternalGpg  # backend-agnostic but we have to pick one
        e.backendLog = "Valid-Until enforcement"
        raise e
      return
