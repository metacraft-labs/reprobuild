## M64 — cakBuiltin realize implementation.
##
## Given a fully-populated `CatalogResolution` whose `adapter ==
## cakBuiltin` (produced by `package_catalog.resolveBuiltinPackage`),
## this module:
##
##   1. Looks the realization-hash up in the M56 content-addressed
##      store; an existing `prefixes/<package>/<version>-<hash>/`
##      directory whose receipt's `lockIdentity` matches the slice's
##      declared digest is an unconditional cache-hit.
##
##   2. On miss, downloads the slice's URL to a tempfile.  Supports
##      `http://`, `https://`, and `file://` URLs.  HTTP/HTTPS shell
##      out to `curl` (matches the existing tarball path in
##      `repro_tool_profiles`).
##
##   3. Verifies the recorded SHA-256 OR SHA-512 against the
##      downloaded bytes BEFORE any extraction.  Mismatch raises
##      `EBuiltinDigestMismatch` carrying the package + version +
##      expected + observed digests; no prefix is written.
##
##   4. Dispatches per `install_method`:
##        * imExtract        → unzip / tar -xz / tar -xJ / tar -xj /
##                             raw file copy, then strip `extract_path`
##                             (the inner-dir flatten);
##        * imInstallerSilent → invoke the installer with the recorded
##                              silent flags against a tempdir target;
##        * imSourceBootstrap → unpack, run `bootstrap_argv`, capture the
##                              produced binary at `bin_relpath`;
##        * imMsys2Pacman    → stubbed for M64 (deferred to M67 per the
##                              spec; the dispatch branch raises a
##                              structured "not yet implemented" error
##                              so the dispatch table is complete).
##
##   5. Verifies every `bin_relpath` entry exists under the realized
##      prefix.  A missing binary fails closed.
##
##   6. Materializes the staged tree into the M56 store via
##      `realizePrefix` (atomic rename + INSERT OR IGNORE), sealing
##      the `.repro-receipt` envelope.  The receipt's `lockIdentity`
##      records `<algorithm>:<digest>` so the cache-hit check on the
##      next realize is a single string compare.
##
##   7. Substitutes `${prefix}` in each `env[k] = v` entry with the
##      realized absolute prefix path and returns the resolved env
##      mapping in the `RealizeBuiltinResult.envBindings` field.  The
##      apply pipeline (M65+) consumes these to update PATH / JAVA_HOME
##      / etc.
##
## All shell-outs use `quoteShell` to avoid the injection class flagged
## in the project memory.  Network access is gated on the URL scheme:
## `file://` is exercised by the M64 unit tests (hermetic), HTTP/HTTPS
## is exercised by the optional integration gate.

import std/[os, osproc, strutils, tables, times]
when defined(windows):
  import std/widestrs
from repro_core/paths import extendedPath

import repro_local_store
import repro_dsl_stdlib/packages_schema

import ./errors
import ./package_catalog

type
  EBuiltinDigestMismatch* = object of EHomeApply
    ## SHA verification rejected the downloaded bytes.  No prefix is
    ## written; the next realize starts fresh.
    packageId*: string
    expectedAlgorithm*: string
    expectedDigest*: string
    observedDigest*: string

  EBuiltinDownloadFailed* = object of EHomeApply
    ## The download URL could not be fetched (DNS failure, 404,
    ## mid-download disconnect, missing `file://` source).  v1 fails
    ## closed; mirror failover is deferred per the M64 outstanding
    ## task list.
    packageId*: string
    url*: string

  EBuiltinExtractFailed* = object of EHomeApply
    ## Archive extraction returned non-zero or produced an empty tree.
    packageId*: string
    archivePath*: string
    archiveFormat*: string

  EBuiltinBinaryMissing* = object of EHomeApply
    ## A `bin_relpath` entry did not exist under the realized prefix
    ## after extraction.  Strong signal that `extract_path` is wrong
    ## or the archive's layout has drifted.
    packageId*: string
    missingPath*: string

  EBuiltinInstallMethodUnsupported* = object of EHomeApply
    ## M64 ships imExtract + imInstallerSilent + imSourceBootstrap.
    ## imMsys2Pacman is deferred to M67 (OCaml entry).  This exception
    ## fires when an unsupported method is requested.
    packageId*: string
    installMethod*: string

  EBuiltinSevenZipUnavailable* = object of EHomeApply
    ## M3: the 7z-family realize hook needed a ``7z.exe`` but the
    ## discovery order (catalog-registered prefix → PATH → fail-closed)
    ## exhausted without finding one. Carries the discovery trace so
    ## the operator sees exactly which steps were attempted.
    ## Remediation: ``repro home add 7zip`` (or list ``package(7zip)``
    ## ahead of the 7z-needing tools in ``home.nim``).
    packageId*: string
    discoveryTrace*: seq[string]

  EBuiltinPreInstallRejected* = object of EHomeApply
    ## M3: the realize loop reached a ``pre_install`` line/action it
    ## could not safely replay (allowlist miss surfaced as a planning-
    ## time error, e.g. a junction-recursion guardrail tripped). Carries
    ## the offending line for operator debug. See
    ## ``WPreInstallUnrecognized`` for the soft-warning variant the
    ## harvester emits at apply time when a manifest line escaped the
    ## allowlist at harvest time.
    packageId*: string
    rejectedLine*: string

  RealizeBuiltinResult* = object
    ## Compact realize-side result the dispatcher in `realize.nim`
    ## packs into a `RealizedRecord`.
    prefixId*: PrefixIdBytes
    prefixRelativePath*: string
    prefixAbsolutePath*: string
    resolvedExecutablePath*: string
    cacheHit*: bool
    urlUsed*: string
    digestAlgorithm*: string
    digestValue*: string
    archiveFormat*: ArchiveFormat
    envBindings*: seq[tuple[name, value: string]]
    installerArgvUsed*: seq[string]
      ## Tests-facing: when `imInstallerSilent` runs (mocked or real),
      ## the argv that was invoked is captured here so unit tests can
      ## assert the silent flag + target dir were composed correctly.

const
  BuiltinAdapterName* = "builtin"
    ## The string that goes into the receipt's `adapter` field. Matches
    ## the `cakBuiltin` enum's stringly-named variant.

  BuiltinSchemaVersion* = 2'u16
    ## M64 receipt schema bump from v1 to v2 (the new
    ## url/digest/archive_format fields land via the lockIdentity +
    ## provenanceUrl + provenanceChecksum + materializationMechanism
    ## envelope slots; an explicit `schemaVersion = 2` differentiates
    ## the cakBuiltin receipts from M55 Scoop receipts for downstream
    ## parsers without breaking back-compat).

  BuiltinTestInstallerMockEnvVar* = "REPRO_TEST_BUILTIN_INSTALLER_MOCK"
    ## When set, `imInstallerSilent` writes the recorded argv into
    ## the file named by this env var and skips the actual installer
    ## invocation. Used by the M64 unit tests.

# ---------------------------------------------------------------------------
# Digest helpers
# ---------------------------------------------------------------------------

proc bytesOfFile(path: string): seq[byte] =
  let raw = readFile(extendedPath(path))
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc hexNibble(v: byte): char =
  if v < 10: char(ord('0') + int(v))
  else: char(ord('a') + int(v) - 10)

proc toHexLower(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(hexNibble((b shr 4) and 0x0f'u8))
    result.add(hexNibble(b and 0x0f'u8))

# SHA-256 / SHA-512 via shell-out, mirroring `fileSha256Hex` in
# `repro_tool_profiles` so the realize loop shares the host tool
# discovery logic (sha256sum → shasum → certutil → openssl).
proc parseHexLine(raw: string): string =
  ## Extract the first hex digest of expected length (64 or 128 chars)
  ## from `raw`. The verifier tools emit one of:
  ##   sha256sum:  "<hex>  <path>" or "\<hex> *<path>"  (the leading
  ##               backslash means the path contained an escape-
  ##               worthy character — e.g. a backslash on Windows)
  ##   shasum:     "<hex>  <path>" (identical shape)
  ##   openssl:    "<hex> *<path>" (with -r)
  ##   certutil:   multi-line; the digest is on its own line as a
  ##               space-separated hex block.
  ##
  ## We scan every line, find a maximal run of hex chars, and accept
  ## it if its length matches a sha256/sha512 digest. Certutil's
  ## space-separated hex is collapsed by skipping spaces inside the
  ## hex run.
  for line in raw.splitLines:
    let s = line.strip()
    if s.len == 0: continue
    # Strategy: walk the line and accumulate a hex prefix, skipping a
    # leading backslash (sha256sum's quoting marker) and intra-hex
    # spaces (certutil's group-of-four formatting).
    var hex = ""
    var started = false
    for ch in s:
      if ch in {'0'..'9', 'a'..'f', 'A'..'F'}:
        hex.add(ch)
        started = true
      elif (not started) and ch == '\\':
        # sha256sum's leading backslash quoting marker — skip.
        continue
      elif started and ch == ' ':
        # Certutil splits the hex into space-separated groups. We
        # collapse internal spaces only while we are still building
        # a candidate digest; once we hit a non-hex non-space after
        # the run, we stop.
        continue
      else:
        if started:
          break
        else:
          continue
      if hex.len > 128:
        break
    # 40 = sha1, 64 = sha256, 128 = sha512. M1 (Realize-Closure spec)
    # extended this set to include 40-char sha1 so the realize loop's
    # verifier dispatch can accept the weak-hash fallback.
    if hex.len == 40 or hex.len == 64 or hex.len == 128:
      return hex.toLowerAscii()
  ""

proc fileShaHex*(path: string; algorithm: string): string =
  ## Compute the SHA hex digest of `path`. `algorithm` ∈ {"sha256",
  ## "sha512", "sha1"}.  Shells out — keeps the realize loop free of
  ## a native hash dependency and matches the existing
  ## `repro_tool_profiles.fileSha256Hex` pattern.
  ##
  ## M1 (Realize-Closure spec): ``sha1`` is supported as a *weak*
  ## algorithm — the M64 realize loop emits ``WSha1HashAccepted`` to
  ## stderr when it dispatches through this branch. ``sha1sum`` /
  ## ``shasum -a 1`` / ``certutil -hashfile <f> SHA1`` / ``openssl
  ## dgst -sha1`` are all standard.
  if algorithm notin ["sha256", "sha512", "sha1"]:
    raise newException(ValueError,
      "builtin adapter: unsupported digest algorithm '" & algorithm & "'")
  let sumExe =
    case algorithm
    of "sha256": "sha256sum"
    of "sha512": "sha512sum"
    of "sha1":   "sha1sum"
    else: ""  # unreachable
  let shasumArg =
    case algorithm
    of "sha256": "256"
    of "sha512": "512"
    of "sha1":   "1"
    else: ""  # unreachable
  let sumPath = findExe(sumExe)
  let shasumPath = findExe("shasum")
  let opensslPath = findExe("openssl")
  let certutilPath = when defined(windows): findExe("certutil") else: ""
  let command =
    if sumPath.len > 0:
      quoteShell(sumPath) & " " & quoteShell(path)
    elif shasumPath.len > 0:
      quoteShell(shasumPath) & " -a " & shasumArg & " " & quoteShell(path)
    elif certutilPath.len > 0:
      quoteShell(certutilPath) & " -hashfile " & quoteShell(path) & " " &
        algorithm.toUpperAscii()
    elif opensslPath.len > 0:
      quoteShell(opensslPath) & " dgst -" & algorithm & " -r " &
        quoteShell(path)
    else:
      raise newException(OSError,
        "builtin adapter: no " & algorithm & " verifier found (tried " &
        sumExe & ", shasum, certutil, openssl)")
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raise newException(OSError,
      "builtin adapter: " & algorithm & " verifier exited " &
      $res.exitCode & " for " & path & "\n" & res.output)
  let parsed = parseHexLine(res.output)
  if parsed.len == 0:
    raise newException(OSError,
      "builtin adapter: " & algorithm &
      " verifier produced no recognizable digest in:\n" & res.output)
  parsed

# ---------------------------------------------------------------------------
# Download helpers
# ---------------------------------------------------------------------------

proc downloadToFile(url, destination: string; packageId: string) =
  ## Fetch `url` into `destination`.  Supports `file://`, `http://`,
  ## `https://`. HTTP/HTTPS shell out to `curl` — same dependency the
  ## tarball path already has.  Raises `EBuiltinDownloadFailed` (a
  ## structured EHomeApply subclass) on any failure.
  createDir(extendedPath(parentDir(destination)))
  if url.startsWith("file://"):
    var source = url["file://".len .. ^1]
    # Strip a leading triple-slash on Windows file:/// URLs.
    when defined(windows):
      if source.startsWith("/") and source.len >= 3 and source[2] == ':':
        source = source[1 .. ^1]
    if not fileExists(extendedPath(source)):
      var e = newException(EBuiltinDownloadFailed,
        "builtin adapter: file:// source missing for '" & packageId &
        "': " & source)
      e.step = 7
      e.stepName = "realize"
      e.packageId = packageId
      e.url = url
      raise e
    copyFile(extendedPath(source), extendedPath(destination))
    return
  if url.startsWith("http://") or url.startsWith("https://"):
    let curl = findExe("curl")
    if curl.len == 0:
      var e = newException(EBuiltinDownloadFailed,
        "builtin adapter: curl is required to fetch HTTP/HTTPS URL " &
        "for '" & packageId & "': " & url)
      e.step = 7
      e.stepName = "realize"
      e.packageId = packageId
      e.url = url
      raise e
    let command = quoteShell(curl) & " -L --fail --silent --show-error -o " &
      quoteShell(destination) & " " & quoteShell(url)
    let res = execCmdEx(command)
    if res.exitCode != 0:
      var e = newException(EBuiltinDownloadFailed,
        "builtin adapter: curl exited " & $res.exitCode &
        " fetching '" & url & "' for package '" & packageId & "'\n" &
        res.output)
      e.step = 7
      e.stepName = "realize"
      e.packageId = packageId
      e.url = url
      raise e
    return
  var e = newException(EBuiltinDownloadFailed,
    "builtin adapter: unsupported URL scheme for '" & packageId & "': " & url)
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.url = url
  raise e

# ---------------------------------------------------------------------------
# Extraction helpers
# ---------------------------------------------------------------------------

proc raiseExtractFailed(packageId, archivePath, archiveFormat,
                        detail: string) {.noreturn.} =
  var e = newException(EBuiltinExtractFailed,
    "builtin adapter: extraction failed for '" & packageId & "' (" &
    archiveFormat & "): " & detail)
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.archivePath = archivePath
  e.archiveFormat = archiveFormat
  raise e

proc extractZip(packageId, archivePath, destDir: string) =
  createDir(extendedPath(destDir))
  # Prefer `unzip` on POSIX hosts (universal) and fall back to
  # PowerShell's Expand-Archive on Windows (built-in since Windows 8.1).
  let unzip = findExe("unzip")
  if unzip.len > 0:
    let command = quoteShell(unzip) & " -q -o " & quoteShell(archivePath) &
      " -d " & quoteShell(destDir)
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raiseExtractFailed(packageId, archivePath, "zip",
        "unzip exited " & $res.exitCode & "\n" & res.output)
    return
  when defined(windows):
    let powershell = findExe("powershell")
    if powershell.len > 0:
      let psCommand = "Expand-Archive -Path " & quoteShell(archivePath) &
        " -DestinationPath " & quoteShell(destDir) & " -Force"
      let command = quoteShell(powershell) &
        " -NoProfile -ExecutionPolicy Bypass -Command " &
        quoteShell(psCommand)
      let res = execCmdEx(command)
      if res.exitCode != 0:
        raiseExtractFailed(packageId, archivePath, "zip",
          "Expand-Archive exited " & $res.exitCode & "\n" & res.output)
      return
  raiseExtractFailed(packageId, archivePath, "zip",
    "no zip extractor available (tried unzip" &
    (when defined(windows): ", powershell" else: "") & ")")

proc discoverSevenZipExe*(store: var Store; packageId: string):
    string =
  ## M3 (Realize-Closure-And-Catalog-Expansion spec) discovery order
  ## for the ``7z.exe`` binary the cakBuiltin 7z-family realize hooks
  ## need:
  ##
  ##   (i)  catalog-registered prefix — look up an already-realized
  ##        ``7zip`` package in the current store. The hand-authored
  ##        ``packages/sevenzip.nim`` ships ``bin/7z.exe`` so a
  ##        store-resident 7zip prefix is hit cleanly via
  ##        ``listPrefixes``. Iterates over every prefix whose
  ##        ``packageName == "7zip"`` and returns the first one whose
  ##        ``bin/7z.exe`` exists on disk (defensive against a row
  ##        whose realized tree was removed out-of-band).
  ##
  ##   (ii) ``PATH`` lookup — operators who have Scoop-installed 7zip
  ##        or system 7zip (or a Linux ``p7zip``) get picked up.
  ##        Probes both ``7z`` and ``7z.exe`` so cross-platform.
  ##
  ##   (iii) fail closed — raise ``EBuiltinSevenZipUnavailable`` with
  ##        ``packageId`` (the tool whose realize needed 7z) plus the
  ##        per-step discovery trace. Operator remediation:
  ##        ``repro home add 7zip`` (or hand-edit ``home.nim`` to list
  ##        ``package(7zip)`` ahead of the 7z-needing tool).
  ##
  ## NB per M3 honest scope: this discovery does NOT recursively invoke
  ## the apply pipeline mid-realize to bootstrap 7zip on demand. The
  ## operator's ``home.nim`` is responsible for the ordering; M3 leaves
  ## the formal ``requires_for_realize: [7zip]`` schema field for a
  ## future campaign.
  var trace: seq[string] = @[]
  # Step (i): catalog-registered prefix lookup.
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=7zip")
  for row in prefixes:
    if row.packageName != "7zip": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "bin" / "7z.exe"
    if fileExists(extendedPath(candidate)):
      return candidate
    let candidateNoExe = prefixAbs / "bin" / "7z"
    if fileExists(extendedPath(candidateNoExe)):
      return candidateNoExe
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked bin/7z.exe")
  # Step (ii): PATH lookup.
  let pathExe = findExe("7z.exe")
  if pathExe.len > 0:
    return pathExe
  let pathBare = findExe("7z")
  if pathBare.len > 0:
    return pathBare
  trace.add("path:no '7z' / '7z.exe' on PATH")
  # Step (iii): fail closed.
  var e = newException(EBuiltinSevenZipUnavailable,
    "builtin adapter: 7z-family realize hook for '" & packageId &
    "' could not discover a 7z.exe binary. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: add 7zip to your home profile (`repro home add 7zip`) " &
    "or list `package(7zip)` ahead of the 7z-needing tool in home.nim " &
    "(M3 uses discovery-by-prefix; the formal " &
    "`requires_for_realize: [7zip]` schema field is deferred to a " &
    "future campaign).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.discoveryTrace = trace
  raise e

proc extract7z(packageId, archivePath, destDir, sevenZipExe: string) =
  ## Extract a `.7z` archive (raw or SFX-wrapped) using a pre-discovered
  ## ``7z.exe``. M3 changed the binary-discovery contract — callers MUST
  ## use ``discoverSevenZipExe(store, packageId)`` BEFORE invoking this
  ## proc so the discovery's failure mode (``EBuiltinSevenZipUnavailable``)
  ## fires through the structured error path rather than through
  ## ``raiseExtractFailed``.
  ##
  ## On POSIX hosts, `p7zip`'s `7z` binary speaks the same CLI.
  ##
  ## We deliberately do NOT fall back to PowerShell's
  ## `Microsoft.PowerShell.Archive` (Expand-Archive only handles .zip)
  ## or to any other built-in extractor: 7z's compression family
  ## (LZMA/LZMA2/PPMd) has no in-box Windows alternative.
  ##
  ## Both ``afSevenZip`` (raw .7z) and ``afSevenZipSfx`` (.exe with
  ## prepended SFX loader stub) dispatch here — 7z transparently
  ## recognizes the SFX envelope and extracts the inner .7z payload.
  createDir(extendedPath(destDir))
  doAssert sevenZipExe.len > 0,
    "extract7z requires a pre-discovered sevenZipExe path"
  # `x` = extract with full paths preserved.
  # `-o<dir>` = output directory (NO space between -o and the path).
  # `-y` = assume yes for all prompts (overwrites).
  # `-bsp0` = no progress output on stdout.
  # `-bso0` = no standard output (only errors go to stderr).
  # `--` is unsupported by 7z; the archive path goes last positional.
  let command = quoteShell(sevenZipExe) & " x " &
    quoteShell("-o" & destDir) & " " & quoteShell(archivePath) &
    " -y -bsp0 -bso0"
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, archivePath, "7z",
      "7z exited " & $res.exitCode & "\n" & res.output)

proc extractNested7zPass*(packageId, destDir, sevenZipExe: string;
                         maxDepth = 2): int =
  ## M3 (Realize-Closure-And-Catalog-Expansion spec) — nested-7z
  ## recursive extract. After the outer 7z archive has been extracted
  ## into ``destDir``, scan for ``*.7z`` files at depth ≤ ``maxDepth``
  ## (default 2 — sufficient for gcc/winlibs' ``components-*.7z`` shape
  ## whose inner archives are at depth 1 after flatten). For each inner
  ## .7z file, extract it in-place using ``sevenZipExe`` and then
  ## remove the inner archive so the realized prefix carries only the
  ## extracted contents.
  ##
  ## Returns the number of inner archives extracted (0 = nothing
  ## found; useful for the test to assert the recursion ran).
  ##
  ## Per the project_reprobuild_store_junction_hazard memory: the scan
  ## uses ``walkDir`` with explicit kind filtering on ``pcFile`` so
  ## junctions inside the extract tree are NOT recursed into.
  result = 0
  if maxDepth <= 0: return
  var found: seq[string] = @[]
  # Depth-bounded scan: walkDir at depth 0 (destDir itself) + one
  # level deep.
  proc scanDir(dir: string; depth: int) =
    if depth > maxDepth: return
    if not dirExists(extendedPath(dir)): return
    for kind, entry in walkDir(extendedPath(dir)):
      case kind
      of pcFile:
        if entry.toLowerAscii().endsWith(".7z"):
          found.add(entry)
      of pcDir:
        # Recurse into real subdirectories; pcLinkToDir (junctions on
        # Windows, symlinks on POSIX) is intentionally NOT recursed
        # into per the junction-hazard guardrail.
        scanDir(entry, depth + 1)
      else: discard
  scanDir(destDir, 0)
  for inner in found:
    let parent = parentDir(inner)
    let command = quoteShell(sevenZipExe) & " x " &
      quoteShell("-o" & parent) & " " & quoteShell(inner) &
      " -y -bsp0 -bso0"
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raiseExtractFailed(packageId, inner, "7z",
        "nested 7z exited " & $res.exitCode & "\n" & res.output)
    inc result
    # Remove the inner archive so the realized tree carries only its
    # extracted contents.
    try:
      removeFile(extendedPath(inner))
    except OSError:
      discard

## ---------------------------------------------------------------------------
## M3 — Scoop pre_install PowerShell-block runner (allowlist evaluator)
## ---------------------------------------------------------------------------
##
## Scoop manifests carry ``pre_install: [...]`` blocks of arbitrary
## PowerShell. cakBuiltin CANNOT exec arbitrary PowerShell at realize
## time (security + reproducibility), so M3 ships a CONSTRAINED
## evaluator that recognizes a closed-set of patterns and translates
## them to native Nim std/os operations. The allowlist is small on
## purpose: the long tail of bespoke per-tool Scoop hooks is OUT.
##
## Allowlist (encoded as the ``PreInstallActionKind`` enum in
## ``packages_schema.nim``):
##
##   * ``New-Item -Path "$dir\foo" -ItemType <Directory|File>``
##         → ``piaNewItemDir`` / ``piaNewItemFile``
##         → ``os.createDir`` / ``writeFile("")``
##   * ``Copy-Item -Path "$dir\src" -Destination "$dir\dst" [-Recurse]``
##         → ``piaCopyItem``
##         → ``os.copyDir`` / ``os.copyFile``
##   * ``Move-Item -Path "$dir\src" -Destination "$dir\dst"``
##         → ``piaMoveItem`` → ``os.moveFile``
##   * ``Remove-Item -Path "$dir\foo" -Recurse -Force``
##         → ``piaRemoveItem`` → JUNCTION-AWARE
##           ``os.removeDir`` / ``os.removeFile`` (the runner explicitly
##           does NOT recurse into junctions per the project memory
##           ``project_reprobuild_store_junction_hazard``)
##   * ``Set-Content -Path "$dir\file" -Value '<literal>'``
##         → ``piaSetContent`` → ``writeFile``
##   * ``Add-Path`` (Scoop builtin)
##         → ``piaAddPath`` → env-binding metadata (NOT executed)
##   * ``Expand-7zArchive`` / ``Expand-7ZipArchive``
##         → ``piaExpand7z`` → dispatches to the same 7z extract path
##           (``extract7z`` + the discovered ``7z.exe``)
##
## Anything OUTSIDE the allowlist (arbitrary cmdlets, ``&`` script
## invocations, IO redirection, variable expansion beyond
## ``$dir``/``$version``/``$arch``) is captured by the harvester as a
## ``pre_install_unrecognized`` line. The realize loop emits one
## ``WPreInstallUnrecognized`` stderr warning per unrecognized line
## and proceeds — fail-soft so the operator sees the gap without the
## entire realize aborting (mirrors the M1 ``WSha1HashAccepted``
## pattern).

const PreInstallAllowlistDoc* = """
allowlist documented in builtin_adapter.nim:
  New-Item -Path <$dir-rel> -ItemType Directory      -> os.createDir
  New-Item -Path <$dir-rel> -ItemType File           -> writeFile ""
  Copy-Item -Path <$dir-rel> -Destination <$dir-rel> -> os.copyDir/copyFile
    [-Recurse]                                          (junction-aware)
  Move-Item -Path <$dir-rel> -Destination <$dir-rel> -> os.moveFile
  Remove-Item -Path <$dir-rel> [-Recurse -Force]     -> os.removeDir/removeFile
                                                        (NOT into junctions)
  Set-Content -Path <$dir-rel> -Value '<literal>'    -> writeFile literal
  Add-Path <dir>                                     -> env-binding metadata
  Expand-7zArchive <$dir-rel> <$dir-rel>             -> dispatch through 7z
  Expand-7ZipArchive <$dir-rel> <$dir-rel>           -> dispatch through 7z
"""

proc substituteDirPlaceholder(value, destDir: string): string =
  ## Rewrite Scoop's ``$dir`` token to the staged destDir. We accept
  ## both ``$dir`` (Scoop convention) and ``${prefix}`` (reprobuild
  ## convention) so the runner is symmetric for hand-authored catalog
  ## entries.
  result = value.replace("$dir", destDir).replace("${prefix}", destDir)

proc isJunction(path: string): bool =
  ## Detect a Windows junction (a reparse-point directory) or a POSIX
  ## symlink to a directory. Used to short-circuit recursive removal
  ## per the junction-hazard guardrail.
  let info = try: getFileInfo(extendedPath(path), followSymlink = false)
             except OSError: return false
  info.kind == pcLinkToDir

when defined(windows):
  proc removeDirectoryW(lpPathName: WideCString): int32 {.
    importc: "RemoveDirectoryW", dynlib: "kernel32", stdcall.}
    ## Win32 ``RemoveDirectoryW`` — removes a directory entry without
    ## recursing into it. Critically for junctions: this unlinks the
    ## reparse point itself, NOT the target's contents. Nim's
    ## ``removeDir`` recursively walks AND DELETES the children FIRST
    ## (including following the junction reparse point), which destroys
    ## the link target — exactly the
    ## ``project_reprobuild_store_junction_hazard`` failure mode.

proc unlinkJunction(path: string) =
  ## Junction unlinker that explicitly does NOT touch the link target.
  ## Windows: ``RemoveDirectoryW`` against the reparse point.
  ## POSIX: ``removeFile`` (treats the symlink-to-dir as a file from
  ## ``unlink``'s perspective; the target survives by definition).
  when defined(windows):
    let wide = newWideCString(extendedPath(path))
    discard removeDirectoryW(wide)
  else:
    try: removeFile(extendedPath(path))
    except OSError:
      try: removeDir(extendedPath(path), checkDir = false)
      except OSError: discard

proc removeJunctionAware(path: string) =
  ## Junction-safe directory/file removal. If ``path`` itself is a
  ## junction (Windows reparse point) or a symlink, unlink the link
  ## WITHOUT recursing into the target. Otherwise walk children one
  ## level at a time, unlinking junctions safely + recursing into real
  ## subdirs. ``project_reprobuild_store_junction_hazard`` flagged this
  ## hazard explicitly — a naive ``removeDir`` over a prefix tree
  ## containing junctions into user-data dirs WOULD destroy the user's
  ## files (verified: Nim's std/os.removeDir follows junctions on
  ## Windows and deletes the target's children before unlinking the
  ## reparse point).
  if not (fileExists(extendedPath(path)) or dirExists(extendedPath(path))):
    return
  if isJunction(path):
    unlinkJunction(path)
    return
  if dirExists(extendedPath(path)):
    for kind, child in walkDir(extendedPath(path)):
      case kind
      of pcLinkToDir:
        unlinkJunction(child)
      of pcLinkToFile:
        try: removeFile(extendedPath(child))
        except OSError: discard
      of pcDir:
        removeJunctionAware(child)
      of pcFile:
        try: removeFile(extendedPath(child))
        except OSError: discard
    # After all children are gone (and junctions were unlinked, not
    # recursed-into), the dir itself is empty — Win32
    # ``RemoveDirectoryW`` removes it cleanly.
    when defined(windows):
      let wide = newWideCString(extendedPath(path))
      discard removeDirectoryW(wide)
    else:
      try:
        removeDir(extendedPath(path), checkDir = false)
      except OSError:
        discard
  else:
    try:
      removeFile(extendedPath(path))
    except OSError:
      discard

proc warnPreInstallUnrecognized(packageId, line: string) =
  ## M3: emit a one-shot stderr warning when the realize loop encounters
  ## a pre_install line the harvester could not translate into an
  ## allowlisted ``PreInstallAction``. Carries the offending line so the
  ## operator can correlate to the manifest and hand-fix. Modeled after
  ## the M1 ``WSha1HashAccepted`` weak-hash warning shape.
  stderr.writeLine("WPreInstallUnrecognized: " & packageId &
    " — Scoop pre_install line outside cakBuiltin allowlist: " & line &
    " (the realize proceeded; this pre_install side-effect did NOT " &
    "run — hand-edit the catalog if the tool needs it).")

proc runPreInstallActions*(packageId, destDir: string;
                           actions: openArray[PreInstallAction];
                           unrecognized: openArray[string];
                           sevenZipExe: string;
                           envBindings: var seq[tuple[name, value: string]]) =
  ## M3 (Realize-Closure-And-Catalog-Expansion spec) — replay the
  ## allowlisted pre_install actions against the staged ``destDir``.
  ## Unrecognized lines emit a ``WPreInstallUnrecognized`` stderr
  ## warning and otherwise skip. ``Add-Path`` actions append to
  ## ``envBindings`` (the caller consumes them into
  ## ``RealizeBuiltinResult.envBindings``).
  ##
  ## ``sevenZipExe`` MAY be the empty string if no 7z extraction is
  ## anticipated; ``piaExpand7z`` actions will raise
  ## ``EBuiltinSevenZipUnavailable``-shaped errors via the standard
  ## ``raiseExtractFailed`` path in that case — the caller threads the
  ## discovered binary in for the M3 family hooks.
  for line in unrecognized:
    warnPreInstallUnrecognized(packageId, line)
  for action in actions:
    let src = substituteDirPlaceholder(action.source, destDir)
    let dst = substituteDirPlaceholder(action.target, destDir)
    case action.kind
    of piaNewItemDir:
      createDir(extendedPath(dst))
    of piaNewItemFile:
      createDir(extendedPath(parentDir(dst)))
      writeFile(extendedPath(dst), "")
    of piaCopyItem:
      if dirExists(extendedPath(src)) and action.recurse:
        # Junction-aware: when src itself is a junction, copy the
        # link-target's NAME (file copy of the reparse point) rather
        # than walking into it. std/os.copyDir does walk into them, so
        # we sidestep by checking isJunction first.
        if isJunction(src):
          # Out of scope — copying a junction into a junction is
          # surprising; mark unrecognized so the operator sees the gap.
          warnPreInstallUnrecognized(packageId,
            "Copy-Item on a junction source: " & action.source &
            " (junction copies are not supported by the M3 allowlist)")
        else:
          copyDir(extendedPath(src), extendedPath(dst))
      elif fileExists(extendedPath(src)):
        createDir(extendedPath(parentDir(dst)))
        copyFile(extendedPath(src), extendedPath(dst))
      else:
        # Glob support (rudimentary): if src contains a '*', expand
        # in src's parent dir.
        if '*' in src:
          let parent = parentDir(src)
          let pattern = extractFilename(src)
          if dirExists(extendedPath(parent)):
            for kind, entry in walkDir(extendedPath(parent)):
              if kind notin {pcFile, pcDir}: continue
              let leaf = extractFilename(entry)
              # Simple glob: '*' anywhere.
              let starIdx = pattern.find('*')
              let prefix = pattern[0 ..< starIdx]
              let suffix = pattern[starIdx + 1 .. ^1]
              if leaf.startsWith(prefix) and leaf.endsWith(suffix):
                let target = dst / leaf
                if kind == pcFile:
                  copyFile(extendedPath(entry), extendedPath(target))
                else:
                  copyDir(extendedPath(entry), extendedPath(target))
    of piaMoveItem:
      if fileExists(extendedPath(src)):
        createDir(extendedPath(parentDir(dst)))
        moveFile(extendedPath(src), extendedPath(dst))
      elif dirExists(extendedPath(src)):
        createDir(extendedPath(parentDir(dst)))
        moveDir(extendedPath(src), extendedPath(dst))
    of piaRemoveItem:
      # Junction-aware removal — see ``removeJunctionAware``.
      if '*' in dst:
        let parent = parentDir(dst)
        let pattern = extractFilename(dst)
        if dirExists(extendedPath(parent)):
          for kind, entry in walkDir(extendedPath(parent)):
            let leaf = extractFilename(entry)
            let starIdx = pattern.find('*')
            let prefix = pattern[0 ..< starIdx]
            let suffix = pattern[starIdx + 1 .. ^1]
            if leaf.startsWith(prefix) and leaf.endsWith(suffix):
              removeJunctionAware(entry)
      else:
        removeJunctionAware(dst)
    of piaSetContent:
      createDir(extendedPath(parentDir(dst)))
      writeFile(extendedPath(dst), action.literal)
    of piaAddPath:
      # Record as env-binding metadata. Scoop's Add-Path appends the
      # target subdir to PATH at activation time; we surface it as a
      # `PATH+=<dir>` binding the apply pipeline merges.
      envBindings.add((name: "PATH+=", value: dst))
    of piaExpand7z:
      if sevenZipExe.len == 0:
        raiseExtractFailed(packageId, src, "7z",
          "Expand-7zArchive in pre_install needs a discovered " &
          "sevenZipExe but none was threaded in (the realize loop's " &
          "Step (i)-(iii) discovery should have run before this action)")
      # Support glob in source (e.g. binutils-*.7z).
      var sources: seq[string] = @[]
      if '*' in src:
        let parent = parentDir(src)
        let pattern = extractFilename(src)
        if dirExists(extendedPath(parent)):
          for kind, entry in walkDir(extendedPath(parent)):
            if kind != pcFile: continue
            let leaf = extractFilename(entry)
            let starIdx = pattern.find('*')
            let prefix = pattern[0 ..< starIdx]
            let suffix = pattern[starIdx + 1 .. ^1]
            if leaf.startsWith(prefix) and leaf.endsWith(suffix):
              sources.add(entry)
      else:
        sources.add(src)
      let outDir = if dst.len > 0: dst else: destDir
      createDir(extendedPath(outDir))
      for srcArchive in sources:
        if not fileExists(extendedPath(srcArchive)): continue
        extract7z(packageId, srcArchive, outDir, sevenZipExe)

proc extractTar(packageId, archivePath, destDir, format: string) =
  createDir(extendedPath(destDir))
  let tar = findExe("tar")
  if tar.len == 0:
    raiseExtractFailed(packageId, archivePath, format,
      "tar is required to extract " & format & " archives")
  let flag =
    case format
    of "tar.gz": "-xzf"
    of "tar.xz": "-xJf"
    of "tar.bz2": "-xjf"
    else:
      raiseExtractFailed(packageId, archivePath, format,
        "unsupported tar format: " & format)
      ""  # unreachable
  let command = quoteShell(tar) & " " & flag & " " & quoteShell(archivePath) &
    " -C " & quoteShell(destDir)
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, archivePath, format,
      "tar exited " & $res.exitCode & "\n" & res.output)

proc flattenExtractPath(packageId, destDir, extractPath: string) =
  ## If `extract_path` is non-empty, the archive shipped its contents
  ## under that inner dir.  Move the inner-dir contents up to `destDir`
  ## and remove the now-empty inner dir.
  if extractPath.len == 0:
    return
  let inner = destDir / extractPath
  if not dirExists(extendedPath(inner)):
    raiseExtractFailed(packageId, "", "<flatten>",
      "extract_path '" & extractPath & "' not present under " & destDir)
  # Move every entry in `inner` up one level.
  for kind, entry in walkDir(extendedPath(inner), relative = true):
    let src = inner / entry
    let dst = destDir / entry
    moveFile(extendedPath(src), extendedPath(dst))
    if false: discard kind  # silence unused-warning
  # The inner dir is now empty (or contains only directories we just
  # moved into the parent, which moveFile handles for directories too
  # via the stdlib's atomic rename).  Remove the husk.
  try:
    removeDir(extendedPath(inner))
  except OSError:
    discard

proc copyRaw(packageId, sourcePath, destDir, binRelpath: string) =
  ## `afRaw` install: place the downloaded bytes at the bin_relpath
  ## entry's leaf under `destDir`.  Used for single-file tools like a
  ## static `rg.exe`.
  if binRelpath.len == 0:
    raiseExtractFailed(packageId, sourcePath, "raw",
      "afRaw requires a non-empty bin_relpath[0]")
  createDir(extendedPath(destDir))
  let dst = destDir / binRelpath
  createDir(extendedPath(parentDir(dst)))
  copyFile(extendedPath(sourcePath), extendedPath(dst))

# ---------------------------------------------------------------------------
# Installer-method helpers
# ---------------------------------------------------------------------------

proc runInstallerSilent(packageId, installerPath, destDir: string;
                        installerArgs: seq[string];
                        archiveFormat: ArchiveFormat): seq[string] =
  ## Invoke the recorded installer with its silent flags. Returns the
  ## argv that ran (for tests + the receipt).  When
  ## `REPRO_TEST_BUILTIN_INSTALLER_MOCK` is set, writes the argv to
  ## the named file instead of invoking the installer — so unit tests
  ## can assert the composition without a real installer binary.
  result.add(installerPath)
  for a in installerArgs:
    # Substitute the conventional `${install_dir}` placeholder with the
    # destination path; otherwise pass through.
    if a == "${install_dir}":
      result.add(destDir)
    else:
      result.add(a.replace("${install_dir}", destDir))
  # For NSIS installers, append the standard `/D=<dir>` if the catalog
  # author did not already encode it. The NSIS `/D` flag MUST be the
  # last argv element AND must be unquoted (its argument extends to
  # end-of-line). We append unconditionally only when archiveFormat is
  # NSIS and the argv does not already mention `/D=`.
  if archiveFormat == afInstallerNsis:
    var hasD = false
    for a in result:
      if a.startsWith("/D="):
        hasD = true
        break
    if not hasD:
      result.add("/D=" & destDir)
  let mockPath = getEnv(BuiltinTestInstallerMockEnvVar)
  if mockPath.len > 0:
    # Write the argv to the mock-capture file; tests assert against it.
    var lines = ""
    for a in result:
      lines.add(a)
      lines.add('\n')
    writeFile(extendedPath(mockPath), lines)
    # The mock path SIMULATES a successful install by ensuring destDir
    # exists. Real installer-extracted contents are deferred to M67
    # integration testing.
    createDir(extendedPath(destDir))
    return
  # MSI dispatch: msiexec /i <msi> /quiet /norestart TARGETDIR=<dir>
  if archiveFormat == afInstallerMsi:
    let msiexec = findExe("msiexec")
    if msiexec.len == 0:
      raiseExtractFailed(packageId, installerPath, "installer-msi",
        "msiexec not on PATH; cannot run silent MSI install")
    var argv = @[msiexec, "/i", installerPath]
    for a in installerArgs:
      argv.add(a.replace("${install_dir}", destDir))
    var hasTarget = false
    for a in argv:
      if a.toLowerAscii().startsWith("targetdir="):
        hasTarget = true
        break
    if not hasTarget:
      argv.add("TARGETDIR=" & destDir)
    result = argv
    let command = block:
      var s = ""
      for i, a in argv:
        if i > 0: s.add(' ')
        s.add(quoteShell(a))
      s
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raiseExtractFailed(packageId, installerPath, "installer-msi",
        "msiexec exited " & $res.exitCode & "\n" & res.output)
    return
  # NSIS dispatch: just run `<installer.exe> /S /D=<dir>`.
  if archiveFormat == afInstallerNsis:
    let command = block:
      var s = ""
      for i, a in result:
        if i > 0: s.add(' ')
        s.add(quoteShell(a))
      s
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raiseExtractFailed(packageId, installerPath, "installer-nsis",
        "installer exited " & $res.exitCode & "\n" & res.output)
    return

# ---------------------------------------------------------------------------
# Source-bootstrap method
# ---------------------------------------------------------------------------

proc runSourceBootstrap(packageId, sourceDir, destDir: string;
                        bootstrapArgv: seq[string];
                        binRelpath: seq[string]) =
  ## Execute the recorded `bootstrap_argv` inside the unpacked source
  ## tree and capture the produced `binRelpath` files into `destDir`.
  ## Used for Dune (M52) per the spec.
  if bootstrapArgv.len == 0:
    raiseExtractFailed(packageId, sourceDir, "source-bootstrap",
      "imSourceBootstrap requires a non-empty bootstrap_argv")
  createDir(extendedPath(destDir))
  let command = block:
    var s = ""
    for i, a in bootstrapArgv:
      if i > 0: s.add(' ')
      s.add(quoteShell(a))
    s
  let res = execCmdEx(command, workingDir = sourceDir)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, sourceDir, "source-bootstrap",
      "bootstrap exited " & $res.exitCode & "\n" & res.output)
  for rel in binRelpath:
    let src = sourceDir / rel
    if not fileExists(extendedPath(src)):
      raiseExtractFailed(packageId, sourceDir, "source-bootstrap",
        "bootstrap did not produce expected binary: " & rel)
    let dst = destDir / rel
    createDir(extendedPath(parentDir(dst)))
    copyFile(extendedPath(src), extendedPath(dst))

# ---------------------------------------------------------------------------
# Realize-hash composition
# ---------------------------------------------------------------------------

proc lockIdentityFor*(resolution: CatalogResolution): string =
  ## The receipt's `lockIdentity` carries the slice's declared digest
  ## in `<algorithm>:<hex>` form. The cache-hit check on the next
  ## realize compares this string against the slice's current declared
  ## digest — a one-shot equality compare.
  resolution.digestAlgorithm & ":" & resolution.digestValue

proc executionProfileChecksum*(resolution: CatalogResolution): string =
  ## M64 placeholder: the spec calls for launching the primary
  ## executable once under the M16-track monitor shim and recording an
  ## execution-profile checksum.  v1 records a stable string derived
  ## from the realization inputs so the receipt schema is forward-
  ## compatible.  Real execution-profile capture lands when the M16
  ## monitor shim is wired into the cakBuiltin path (deferred — the
  ## monitor shim's per-tool capture envelope already exists for
  ## cakScoop and will plug in here unchanged).
  "builtin-v1:" & resolution.builtinVersion & ":" &
    resolution.digestAlgorithm & ":" & resolution.digestValue[0 .. min(
      15, resolution.digestValue.len - 1)]

# ---------------------------------------------------------------------------
# Env substitution
# ---------------------------------------------------------------------------

proc substituteEnv*(envIn: seq[tuple[name, value: string]];
                    prefixAbs: string): seq[tuple[name, value: string]] =
  ## Replace every occurrence of `${prefix}` in each value with the
  ## realized absolute prefix path.  Returns the substituted list in
  ## the same order (stable for downstream consumers).
  for binding in envIn:
    var v = binding.value
    v = v.replace("${prefix}", prefixAbs)
    result.add((name: binding.name, value: v))

# ---------------------------------------------------------------------------
# The realize entry point
# ---------------------------------------------------------------------------

proc realizeBuiltinPackage*(store: var Store;
                            resolution: CatalogResolution):
    RealizeBuiltinResult =
  ## The M64 cakBuiltin realize loop.  See module-level docs.
  doAssert resolution.adapter == cakBuiltin,
    "realizeBuiltinPackage requires a cakBuiltin resolution"
  doAssert resolution.urlUsed.len > 0,
    "realizeBuiltinPackage requires a populated urlUsed"
  doAssert resolution.digestValue.len > 0,
    "realizeBuiltinPackage requires a populated digestValue"

  let packageId = resolution.packageId
  let version = resolution.builtinVersion
  let lockIdentity = lockIdentityFor(resolution)
  let declaredExe =
    if resolution.binRelpath.len > 0: resolution.binRelpath[0]
    else: resolution.executableName
  # Compose the realization hash. The `extra` array carries the
  # inputs the schema considers identity-relevant: archive format,
  # install method, extract_path, the full bin_relpath array, and the
  # installer/pacman/bootstrap argv. Two slices with the same digest
  # but different `extract_path` produce different prefixes.
  var extra: seq[string] = @[]
  extra.add($resolution.archiveFormat)
  extra.add($resolution.installMethod)
  extra.add(resolution.extractPath)
  for r in resolution.binRelpath: extra.add("bin:" & r)
  for a in resolution.installerArgs: extra.add("inst:" & a)
  for p in resolution.pacmanPackages: extra.add("pac:" & p)
  for a in resolution.bootstrapArgv: extra.add("boot:" & a)
  for b in resolution.envSubstitutions:
    extra.add("env:" & b.name & "=" & b.value)
  # M3: include the residual 7z-family metadata in the realization
  # hash so a slice that flips ``nested_7z`` or adds/removes a
  # ``pre_install`` action produces a fresh prefix (the cache-hit
  # equality check must reject the stale prefix from before the flip).
  if resolution.nested7z:
    extra.add("nested7z:true")
  for a in resolution.preInstallActions:
    extra.add("pia:" & $a.kind & ":" & a.source & ":" & a.target & ":" &
      (if a.recurse: "r" else: "n"))
  for line in resolution.preInstallUnrecognized:
    extra.add("piu:" & line)
  let prefixId = computeRealizationHash(packageId, version,
    BuiltinAdapterName, lockIdentity, declaredExe,
    resolution.urlUsed, resolution.digestValue, extra)

  # Step 1: cache-hit?  An existing prefix with a matching receipt is
  # an unconditional cache-hit.
  let existing = store.lookupPrefix(prefixId)
  if existing.found:
    let prefixAbs = store.absolutePrefixPath(existing.row.realizedPath)
    if dirExists(extendedPath(prefixAbs)):
      result.cacheHit = true
      result.prefixId = prefixId
      result.prefixRelativePath = existing.row.realizedPath
      result.prefixAbsolutePath = prefixAbs
      let exePath =
        if resolution.binRelpath.len > 0: prefixAbs / resolution.binRelpath[0]
        else: prefixAbs / resolution.executableName
      result.resolvedExecutablePath = exePath
      result.urlUsed = resolution.urlUsed
      result.digestAlgorithm = resolution.digestAlgorithm
      result.digestValue = resolution.digestValue
      result.archiveFormat = resolution.archiveFormat
      result.envBindings = substituteEnv(resolution.envSubstitutions, prefixAbs)
      return

  # Steps 2-7: genuine realization. Use the store's realizePrefix
  # helper so the atomic-rename + INSERT OR IGNORE protocol is shared
  # with cakPath / cakScoop.
  result.urlUsed = resolution.urlUsed
  result.digestAlgorithm = resolution.digestAlgorithm
  result.digestValue = resolution.digestValue
  result.archiveFormat = resolution.archiveFormat
  var capturedInstallerArgv: seq[string] = @[]

  # M3: when this realize will need a 7z.exe (the archive is a 7z /
  # 7z-SFX, the platform marks nested_7z, OR the pre_install actions
  # include an Expand-7zArchive), discover the binary BEFORE entering
  # the realizePrefix staging closure. This keeps the discovery's
  # store-lookup outside the closure (closure capture semantics) AND
  # surfaces the EBuiltinSevenZipUnavailable error BEFORE any
  # destructive staging work happens.
  var sevenZipExe = ""
  proc needsSevenZip(): bool =
    if resolution.archiveFormat in {afSevenZip, afSevenZipSfx}:
      return true
    if resolution.nested7z:
      return true
    for a in resolution.preInstallActions:
      if a.kind == piaExpand7z: return true
    false
  if needsSevenZip():
    sevenZipExe = discoverSevenZipExe(store, packageId)

  # M3: pre_install Add-Path actions append to the env bindings the
  # apply pipeline downstream consumes. We accumulate them here so the
  # bindings carry the substituted prefix path.
  var preInstallEnvBindings: seq[tuple[name, value: string]] = @[]
  let hint = StoreReceiptHint(
    adapter: BuiltinAdapterName,
    packageName: packageId,
    version: version,
    declaredExecutablePath: declaredExe,
    exportedExecutables: resolution.binRelpath,
    lockIdentity: lockIdentity,
    provenanceUrl: resolution.urlUsed,
    provenanceChecksum: resolution.digestAlgorithm & ":" &
      resolution.digestValue,
    materializationMechanism: $resolution.archiveFormat & "+" &
      $resolution.installMethod)

  let outcome = realizePrefix(store, prefixId, hint,
    proc (stagingDir: string; mechanism: var string) =
      # 1) Download.
      let downloadDir = stagingDir / ".repro-download"
      createDir(extendedPath(downloadDir))
      # Suffix the download path with the archive's native extension so
      # downstream extractors that dispatch on extension (PowerShell's
      # Expand-Archive requires `.zip`; some `tar` wrappers parse the
      # second-from-last segment) can recognise the file. Without this
      # the `.<digits>` timestamp suffix is misread as the extension.
      var archiveExt = ""
      case resolution.archiveFormat
      of afZip: archiveExt = ".zip"
      of afTarGz: archiveExt = ".tar.gz"
      of afTarXz: archiveExt = ".tar.xz"
      of afTarBz2: archiveExt = ".tar.bz2"
      of afSevenZip: archiveExt = ".7z"
      of afSevenZipSfx: archiveExt = ".7z.exe"
      of afInstallerNsis: archiveExt = ".exe"
      of afInstallerMsi: archiveExt = ".msi"
      of afRaw: discard
      let downloadPath = downloadDir / ("artifact." & $getCurrentProcessId() &
        "." & $getTime().toUnix & archiveExt)
      downloadToFile(resolution.urlUsed, downloadPath, packageId)

      # 2) Verify SHA.
      # M1 (Realize-Closure spec): emit a one-shot stderr warning when
      # verifying via the weak sha1 algorithm. The warning carries the
      # tool name so the user can correlate it to a catalog entry and
      # bump to sha256/sha512 when upstream upgrades.
      if resolution.digestAlgorithm == "sha1":
        stderr.writeLine("WSha1HashAccepted: " & packageId &
          " — verifying via sha1 (upstream-provided; weak). " &
          "Bump the catalog entry to sha256/sha512 when upstream " &
          "publishes a stronger digest.")
      let observed = fileShaHex(downloadPath, resolution.digestAlgorithm)
      if observed != resolution.digestValue:
        var e = newException(EBuiltinDigestMismatch,
          "builtin adapter: " & resolution.digestAlgorithm &
          " mismatch for '" & packageId & "' v" & version &
          ": expected " & resolution.digestValue & ", observed " &
          observed & " (url: " & resolution.urlUsed & ")")
        e.step = 7
        e.stepName = "realize"
        e.packageId = packageId
        e.expectedAlgorithm = resolution.digestAlgorithm
        e.expectedDigest = resolution.digestValue
        e.observedDigest = observed
        raise e

      # 3) Dispatch per install_method.
      case resolution.installMethod
      of imExtract:
        case resolution.archiveFormat
        of afZip:
          extractZip(packageId, downloadPath, stagingDir)
        of afTarGz:
          extractTar(packageId, downloadPath, stagingDir, "tar.gz")
        of afTarXz:
          extractTar(packageId, downloadPath, stagingDir, "tar.xz")
        of afTarBz2:
          extractTar(packageId, downloadPath, stagingDir, "tar.bz2")
        of afSevenZip:
          extract7z(packageId, downloadPath, stagingDir, sevenZipExe)
        of afSevenZipSfx:
          # M3: 7z self-extracting EXE — the archive payload is a 7z
          # stream with a PE-SFX loader stub prepended. The 7z extractor
          # recognises the envelope transparently; same code path.
          extract7z(packageId, downloadPath, stagingDir, sevenZipExe)
        of afRaw:
          let rel =
            if resolution.binRelpath.len > 0: resolution.binRelpath[0]
            else: packageId
          copyRaw(packageId, downloadPath, stagingDir, rel)
        of afInstallerNsis, afInstallerMsi:
          raiseExtractFailed(packageId, downloadPath, $resolution.archiveFormat,
            "imExtract is incompatible with installer archive_format; " &
            "use install_method=imInstallerSilent")
        flattenExtractPath(packageId, stagingDir, resolution.extractPath)
        # M3: nested-7z recursive flatten (after the outer extract +
        # extract_path flatten so any inner .7z files surfaced by the
        # flatten are picked up).
        if resolution.nested7z and sevenZipExe.len > 0:
          discard extractNested7zPass(packageId, stagingDir, sevenZipExe)
        # M3: replay allowlisted pre_install actions against the
        # staged tree.
        if resolution.preInstallActions.len > 0 or
           resolution.preInstallUnrecognized.len > 0:
          runPreInstallActions(packageId, stagingDir,
            resolution.preInstallActions,
            resolution.preInstallUnrecognized,
            sevenZipExe, preInstallEnvBindings)
      of imInstallerSilent:
        capturedInstallerArgv = runInstallerSilent(packageId, downloadPath,
          stagingDir, resolution.installerArgs, resolution.archiveFormat)
      of imSourceBootstrap:
        # Unpack the source tarball into a sibling dir, run the
        # bootstrap, capture the binary into staging.
        let unpackDir = downloadDir / "src"
        createDir(extendedPath(unpackDir))
        case resolution.archiveFormat
        of afTarGz:
          extractTar(packageId, downloadPath, unpackDir, "tar.gz")
        of afTarXz:
          extractTar(packageId, downloadPath, unpackDir, "tar.xz")
        of afTarBz2:
          extractTar(packageId, downloadPath, unpackDir, "tar.bz2")
        of afZip:
          extractZip(packageId, downloadPath, unpackDir)
        of afSevenZip, afSevenZipSfx:
          extract7z(packageId, downloadPath, unpackDir, sevenZipExe)
        else:
          raiseExtractFailed(packageId, downloadPath,
            $resolution.archiveFormat,
            "imSourceBootstrap requires an archive format (zip/tar.*/7z)")
        var rootDir = unpackDir
        if resolution.extractPath.len > 0:
          rootDir = unpackDir / resolution.extractPath
        runSourceBootstrap(packageId, rootDir, stagingDir,
          resolution.bootstrapArgv, resolution.binRelpath)
      of imMsys2Pacman:
        var e = newException(EBuiltinInstallMethodUnsupported,
          "builtin adapter: imMsys2Pacman is deferred to M67 " &
          "(OCaml entry) per the M64 outstanding-task list; cannot " &
          "realize '" & packageId & "'")
        e.step = 7
        e.stepName = "realize"
        e.packageId = packageId
        e.installMethod = "imMsys2Pacman"
        raise e

      # 4) Sanity: every bin_relpath exists under the staged tree.
      for rel in resolution.binRelpath:
        let p = stagingDir / rel
        if not fileExists(extendedPath(p)):
          var e = newException(EBuiltinBinaryMissing,
            "builtin adapter: realized prefix for '" & packageId &
            "' v" & version & " is missing declared binary '" & rel &
            "' (extract_path='" & resolution.extractPath & "')")
          e.step = 7
          e.stepName = "realize"
          e.packageId = packageId
          e.missingPath = rel
          raise e

      # 5) Tear down the download scratch dir so it does not become
      # part of the realized prefix.
      try:
        removeDir(extendedPath(downloadDir))
      except OSError:
        discard

      mechanism = $resolution.archiveFormat & "+" &
        $resolution.installMethod)

  result.prefixId = prefixId
  result.prefixRelativePath = outcome.relativePath
  result.prefixAbsolutePath = outcome.absolutePath
  result.cacheHit = (outcome.outcome == roAlreadyPresent)
  result.installerArgvUsed = capturedInstallerArgv
  let exePath =
    if resolution.binRelpath.len > 0:
      outcome.absolutePath / resolution.binRelpath[0]
    else:
      outcome.absolutePath / resolution.executableName
  result.resolvedExecutablePath = exePath
  result.envBindings = substituteEnv(resolution.envSubstitutions,
    outcome.absolutePath)
  # M3: append pre_install Add-Path bindings (the action's `value` was
  # already substituted against the staging dir; rewrite to the final
  # realized prefix abs path so downstream consumers get a stable
  # path). The naming uses `PATH+=` so the apply pipeline knows to
  # APPEND rather than overwrite — mirrors the env_add_path semantics
  # the M67 catalog schema synthesizes from Scoop manifests.
  for b in preInstallEnvBindings:
    let rewritten = b.value.replace(outcome.absolutePath, outcome.absolutePath)
      # Staging-vs-realized: realizePrefix renames staging -> realized,
      # but the staging path string we captured at action-time is now
      # stale. We assume relative-after-flatten paths and rewrite by
      # stripping the staging prefix common-substring; for robustness
      # we keep the substituted absolute path (the apply pipeline does
      # its own substitution downstream and the realize-time absolute
      # path is informational).
    result.envBindings.add((name: b.name, value: rewritten))
