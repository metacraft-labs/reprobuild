## D2 P1: GPG / fingerprint verification for the Fedora repomd.xml.
##
## ## Verification strategy
##
## Fedora-style repos publish ``repodata/repomd.xml`` plus an optional
## detached signature at ``repodata/repomd.xml.asc``. We support two
## verification backends, chosen at runtime:
##
##   1. **External GPG** — the preferred backend. Shells out to ``gpg``
##      on $PATH (or $REPRO_GPG_BIN), imports every ``.gpg`` blob under
##      the key-bundle directory into an ephemeral keyring, then runs
##      ``gpg --verify <repomd.xml.asc> <repomd.xml>``. Mirrors what
##      ``dnf`` itself does on a verifying client.
##
##   2. **Fingerprint allowlist** — fallback when no ``gpg`` is on PATH
##      OR when running fixture-driven against a synthetic repo. The
##      operator vendors a ``MANIFEST.txt`` whose lines name the
##      blake3 of the canonical repomd.xml bytes; the harvester refuses
##      to proceed unless the file's blake3 matches one of those
##      entries. Identical contract to ``repro-harvest-apt``'s
##      fingerprint backend.
##
## D2 ships the framework + an allowlist verifier; the Fedora key
## bundle vendoring is deferred to a future maintenance pass (the
## C2 deliverable note for apt promised the same).

import std/[os, osproc, strtabs, strutils]

import blake3

type
  SignatureBackend* = enum
    sbExternalGpg = "external-gpg"
    sbFingerprintAllowlist = "fingerprint-allowlist"

  RepomdVerification* = object
    backend*: SignatureBackend
    signerKeyId*: string
    backendLog*: string

  SignatureVerificationError* = object of CatchableError
    backend*: SignatureBackend
    backendLog*: string

# ---------------------------------------------------------------------------
# Key-bundle discovery
# ---------------------------------------------------------------------------

proc resolveKeyBundleDir*(explicit = ""): string =
  ## Precedence:
  ##   1. ``explicit`` argument (CLI ``--gpg-keys``).
  ##   2. ``$REPRO_DNF_KEY_BUNDLE`` environment variable.
  ##   3. ``recipes/catalog/foreign/dnf/keys/`` resolved from the
  ##      reprobuild repo root via the harvester binary's location.
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_DNF_KEY_BUNDLE")
  if fromEnv.len > 0:
    return fromEnv
  var dir = getAppDir()
  for _ in 0 .. 6:
    let candidate = dir / "recipes" / "catalog" / "foreign" / "dnf" /
      "keys"
    if dirExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  "recipes/catalog/foreign/dnf/keys"

# ---------------------------------------------------------------------------
# Fingerprint allowlist backend
# ---------------------------------------------------------------------------

type
  AllowlistEntry = object
    id: string
    fingerprintHex: string

proc parseAllowlistManifest(text: string): seq[AllowlistEntry] =
  ## Lines of shape ``<id> <64-char-hex-fingerprint>``. Blank lines +
  ## ``#`` comments tolerated.
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

proc verifyRepomdViaAllowlist*(repomdBytes: string;
                              keyBundleDir: string):
    RepomdVerification =
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
      "MANIFEST.txt at " & manifestPath & " has no allowlist entries")
    e.backend = sbFingerprintAllowlist
    e.backendLog = "empty allowlist"
    raise e
  let actual = blake3Hex(repomdBytes)
  for entry in entries:
    if entry.fingerprintHex == actual:
      return RepomdVerification(
        backend: sbFingerprintAllowlist,
        signerKeyId: entry.id,
        backendLog: "allowlist hit on fingerprint " & actual)
  var e = newException(SignatureVerificationError,
    "repomd.xml BLAKE3 fingerprint " & actual &
    " is not in the allowlist at " & manifestPath)
  e.backend = sbFingerprintAllowlist
  e.backendLog = "no allowlist match (expected one of " &
    $entries.len & " fingerprints)"
  raise e

# ---------------------------------------------------------------------------
# External gpg backend (detached sig)
# ---------------------------------------------------------------------------

proc resolveGpgBin*(): string =
  let fromEnv = getEnv("REPRO_GPG_BIN")
  if fromEnv.len > 0: return fromEnv
  let found = findExe("gpg")
  if found.len > 0: return found
  ""

proc verifyRepomdViaExternalGpg*(repomdBytes, repomdAscBytes: string;
                                keyBundleDir: string;
                                gpgBin: string): RepomdVerification =
  ## ``repomdAscBytes`` is the ``repomd.xml.asc`` detached signature.
  let tmpDir = getTempDir() / ("dnf-harvest-gpg-" & $getCurrentProcessId())
  createDir(tmpDir)
  defer:
    try: removeDir(tmpDir)
    except: discard
  let gpgEnv = newStringTable()
  gpgEnv["GNUPGHOME"] = tmpDir
  var importLog = ""
  for kind, path in walkDir(keyBundleDir):
    if kind != pcFile: continue
    if not path.toLowerAscii().endsWith(".gpg"): continue
    let (output, exitCode) = execCmdEx(gpgBin & " --batch --quiet" &
      " --import " & quoteShell(path), env = gpgEnv)
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
  let dataPath = tmpDir / "repomd.xml"
  let sigPath = tmpDir / "repomd.xml.asc"
  writeFile(dataPath, repomdBytes)
  writeFile(sigPath, repomdAscBytes)
  let (verifyOut, verifyExit) = execCmdEx(gpgBin & " --batch --quiet" &
    " --status-fd 1 --verify " & quoteShell(sigPath) & " " &
    quoteShell(dataPath), env = gpgEnv)
  let fullLog = importLog & "verify exit=" & $verifyExit & "\n" &
    verifyOut
  if verifyExit != 0:
    var e = newException(SignatureVerificationError,
      "gpg --verify rejected the repomd.xml (exit " & $verifyExit & ")")
    e.backend = sbExternalGpg
    e.backendLog = fullLog
    raise e
  var signerId = ""
  for line in verifyOut.splitLines:
    if line.startsWith("[GNUPG:] VALIDSIG ") or
       line.startsWith("[GNUPG:] GOODSIG "):
      let parts = line.splitWhitespace()
      if parts.len >= 3:
        signerId = parts[2]
        break
  result = RepomdVerification(
    backend: sbExternalGpg,
    signerKeyId: signerId,
    backendLog: fullLog)

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc verifyRepomd*(repomdBytes: string;
                  keyBundleDir: string;
                  repomdAscBytes = "";
                  preferredBackend = sbExternalGpg):
    RepomdVerification =
  ## Verify the repomd.xml bytes against the vendored key bundle. When
  ## ``repomdAscBytes`` is empty (D2 fixture path) we fall through to
  ## the allowlist backend.
  if preferredBackend == sbExternalGpg and repomdAscBytes.len > 0:
    let gpgBin = resolveGpgBin()
    if gpgBin.len > 0:
      return verifyRepomdViaExternalGpg(repomdBytes, repomdAscBytes,
        keyBundleDir, gpgBin)
  verifyRepomdViaAllowlist(repomdBytes, keyBundleDir)
