## D2 P2: Verification for the pacman repo database.
##
## Arch Linux signs ``<repo>.db`` with a detached ``<repo>.db.sig`` file
## using master keyring entries. Our verifier supports two backends:
##
##   1. **External GPG** — shells out to ``gpg --verify``. Mirrors the
##      apt + dnf harvesters.
##   2. **Fingerprint allowlist** — fallback for fixture-driven CI when
##      no ``gpg`` is on PATH.

import std/[os, osproc, strtabs, strutils]

import blake3

type
  SignatureBackend* = enum
    sbExternalGpg = "external-gpg"
    sbFingerprintAllowlist = "fingerprint-allowlist"

  RepoDbVerification* = object
    backend*: SignatureBackend
    signerKeyId*: string
    backendLog*: string

  SignatureVerificationError* = object of CatchableError
    backend*: SignatureBackend
    backendLog*: string

proc resolveKeyBundleDir*(explicit = ""): string =
  if explicit.len > 0:
    return explicit
  let fromEnv = getEnv("REPRO_PACMAN_KEY_BUNDLE")
  if fromEnv.len > 0:
    return fromEnv
  var dir = getAppDir()
  for _ in 0 .. 6:
    let candidate = dir / "recipes" / "catalog" / "foreign" / "pacman" /
      "keys"
    if dirExists(candidate):
      return candidate
    let parent = parentDir(dir)
    if parent == dir:
      break
    dir = parent
  "recipes/catalog/foreign/pacman/keys"

type
  AllowlistEntry = object
    id: string
    fingerprintHex: string

proc parseAllowlistManifest(text: string): seq[AllowlistEntry] =
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

proc verifyDbViaAllowlist*(dbBytes: string; keyBundleDir: string):
    RepoDbVerification =
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
  let actual = blake3Hex(dbBytes)
  for entry in entries:
    if entry.fingerprintHex == actual:
      return RepoDbVerification(
        backend: sbFingerprintAllowlist,
        signerKeyId: entry.id,
        backendLog: "allowlist hit on fingerprint " & actual)
  var e = newException(SignatureVerificationError,
    "repo db BLAKE3 fingerprint " & actual &
    " is not in the allowlist at " & manifestPath)
  e.backend = sbFingerprintAllowlist
  e.backendLog = "no allowlist match (expected one of " &
    $entries.len & " fingerprints)"
  raise e

proc resolveGpgBin*(): string =
  let fromEnv = getEnv("REPRO_GPG_BIN")
  if fromEnv.len > 0: return fromEnv
  let found = findExe("gpg")
  if found.len > 0: return found
  ""

proc verifyDbViaExternalGpg*(dbBytes, sigBytes: string;
                            keyBundleDir: string;
                            gpgBin: string): RepoDbVerification =
  let tmpDir = getTempDir() / ("pacman-harvest-gpg-" &
    $getCurrentProcessId())
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
  let dataPath = tmpDir / "repo.db"
  let sigPath = tmpDir / "repo.db.sig"
  writeFile(dataPath, dbBytes)
  writeFile(sigPath, sigBytes)
  let (verifyOut, verifyExit) = execCmdEx(gpgBin & " --batch --quiet" &
    " --status-fd 1 --verify " & quoteShell(sigPath) & " " &
    quoteShell(dataPath), env = gpgEnv)
  let fullLog = importLog & "verify exit=" & $verifyExit & "\n" &
    verifyOut
  if verifyExit != 0:
    var e = newException(SignatureVerificationError,
      "gpg --verify rejected the repo db (exit " & $verifyExit & ")")
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
  result = RepoDbVerification(
    backend: sbExternalGpg,
    signerKeyId: signerId,
    backendLog: fullLog)

proc verifyRepoDb*(dbBytes: string;
                  keyBundleDir: string;
                  sigBytes = "";
                  preferredBackend = sbExternalGpg):
    RepoDbVerification =
  if preferredBackend == sbExternalGpg and sigBytes.len > 0:
    let gpgBin = resolveGpgBin()
    if gpgBin.len > 0:
      return verifyDbViaExternalGpg(dbBytes, sigBytes,
        keyBundleDir, gpgBin)
  verifyDbViaAllowlist(dbBytes, keyBundleDir)
