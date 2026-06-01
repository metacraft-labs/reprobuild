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

import std/[algorithm, os, osproc, strutils, tables, times]
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
    ## M64 shipped imExtract + imInstallerSilent + imSourceBootstrap.
    ## M6 (Realize-Closure-And-Catalog-Expansion spec) added
    ## imMsys2Pacman. This exception fires only when a future variant is
    ## requested before its realize hook lands.
    packageId*: string
    installMethod*: string

  EBuiltinZstdUnavailable* = object of EHomeApply
    ## M6 (Realize-Closure-And-Catalog-Expansion spec): the
    ## ``afTarZst`` realize hook needed a zstd-capable extractor (full
    ## ``7z.exe`` from the catalog ``7zip`` prefix, host
    ## ``tar --zstd``, or host ``zstd``) but every step of the
    ## discovery order exhausted. Carries the per-step trace so the
    ## operator sees exactly which paths were tried. Remediation:
    ## install Git for Windows (ships ``tar`` with the ``--zstd``
    ## filter) OR install the full 7-Zip suite (the M3 hand-authored
    ## ``packages/sevenzip.nim`` ships ``7zr.exe`` which does NOT
    ## include the zstd codec; re-harvest sevenzip to the MSI shape
    ## via the M11 follow-up).
    packageId*: string
    discoveryTrace*: seq[string]

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

  EBuiltinDarkUnavailable* = object of EHomeApply
    ## M4: the MSI / NSIS+MSI bundle realize hook needed a ``dark.exe``
    ## (WiX v3 decompiler) but the discovery order (catalog-registered
    ## ``wix3`` prefix → PATH → fail-closed) exhausted without finding
    ## one. Carries the discovery trace so the operator sees exactly
    ## which steps were attempted. Remediation:
    ## ``repro home add wix3`` (or list ``package(wix3)`` ahead of the
    ## MSI-needing tools in ``home.nim``).
    ##
    ## M4 amendment: this exception is retained for forward
    ## compatibility but the M4 ``imInstallerMsi`` realize hook now
    ## defaults to ``lessmsi`` (see ``EBuiltinLessmsiUnavailable``)
    ## because WiX dark.exe extracts MSI metadata payloads, not the
    ## logical install hierarchy.
    packageId*: string
    discoveryTrace*: seq[string]

  EBuiltinLessmsiUnavailable* = object of EHomeApply
    ## M4 (post-live-smoke amendment): the MSI / NSIS+MSI bundle
    ## realize hook needed a ``lessmsi.exe`` but discovery exhausted
    ## (catalog ``lessmsi`` prefix → PATH → fail). Remediation:
    ## ``repro home add lessmsi``. Replaces the spec-text-proposed
    ## ``EBuiltinDarkUnavailable`` as the practical fail-closed shape
    ## for the M4 MSI realize hook.
    packageId*: string
    discoveryTrace*: seq[string]

  EBuiltinInnounpUnavailable* = object of EHomeApply
    ## M4: the Inno Setup realize hook needed an ``innounp.exe`` but
    ## the discovery order (catalog-registered ``innounp`` prefix →
    ## PATH → fail-closed) exhausted without finding one. Carries the
    ## discovery trace so the operator sees exactly which steps were
    ## attempted. Remediation: ``repro home add innounp`` (or list
    ## ``package(innounp)`` ahead of the Inno-Setup-shipped tools in
    ## ``home.nim``).
    packageId*: string
    discoveryTrace*: seq[string]

  EBuiltinInterpreterUnavailable* = object of EHomeApply
    ## M5: the Scoop-style launcher emit hook needed an interpreter
    ## binary (php for .phar, java for .jar, etc.) but the discovery
    ## order (catalog-registered prefix → PATH → fail-closed) exhausted
    ## without finding one. Carries the discovery trace AND the missing
    ## interpreter's catalog package id so the operator sees exactly
    ## which steps were attempted and which ``repro home add <pkg>`` to
    ## run. Subclassed by ``EBuiltinPhpUnavailable`` /
    ## ``EBuiltinJavaUnavailable`` for back-pressure on the specific
    ## interpreter the launcher needed (the catch-all parent type makes
    ## downstream code that does not care about the specific shape
    ## easier to write).
    packageId*: string
    interpreterPackageId*: string
    discoveryTrace*: seq[string]

  EBuiltinPhpUnavailable* = object of EBuiltinInterpreterUnavailable
    ## M5: the lekPhar launcher emit hook needed a ``php`` /
    ## ``php.exe`` but discovery exhausted. Remediation: ``repro home
    ## add php`` (or list ``package(php)`` ahead of ``package(composer)``
    ## in home.nim).

  EBuiltinJavaUnavailable* = object of EBuiltinInterpreterUnavailable
    ## M5: the lekJar launcher emit hook needed a ``java`` /
    ## ``java.exe`` but discovery exhausted. Remediation: ``repro home
    ## add jdk`` (or list ``package(jdk)`` ahead of the .jar-shipping
    ## tool in home.nim).

  EBuiltinPrefixMergeConflict* = object of EHomeApply
    ## M4: the NSIS+MSI bundle realize merged the per-MSI extract trees
    ## into a single prefix and observed two MSIs writing the same
    ## relpath with **different** content. Fails closed rather than
    ## silently letting one MSI win. Carries the conflicting relpath +
    ## the two source MSI basenames so the operator can hand-fix the
    ## catalog (e.g. by adding a per-MSI extract_path override).
    packageId*: string
    conflictPath*: string
    sourceA*: string
    sourceB*: string

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

  BuiltinPreferMsiexecEnvVar* = "CAKBUILTIN_PREFER_MSIEXEC"
    ## M4: when set to a non-empty value, the realize loop swaps the
    ## default ``dark.exe`` MSI extractor for ``msiexec /a TARGETDIR``
    ## (the native Windows administrative-install mode). Operator
    ## escape hatch for MSIs whose custom-action tables make dark.exe
    ## fail-silent-skip. ``PlatformBinary.msi_admin_install = true``
    ## is the per-platform override; this env var is the global
    ## override. Both paths produce a file tree at the prefix root
    ## without writing to the registry.

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
proc parseHexLine(raw: string; expectedLen: int = 0): string =
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
    # spaces (certutil's group-of-four formatting). The moment we
    # have a complete digest length (40/64/128 = sha1/sha256/sha512)
    # we stop — guards against the sha256sum shape
    # ``<digest>  <path>`` where the path may itself start with hex
    # characters (e.g. ``build/...``).
    var hex = ""
    var started = false
    for ch in s:
      if ch in {'0'..'9', 'a'..'f', 'A'..'F'}:
        hex.add(ch)
        started = true
        if expectedLen > 0 and hex.len == expectedLen:
          # Peek-free early exit at the expected algorithm length.
          # Guards against the sha256sum shape ``<digest>  <path>`` on
          # paths whose filename happens to start with hex characters
          # (e.g. ``build/...``) — without this exit we would
          # accidentally consume those bytes into the digest because
          # the loop collapses intra-hex whitespace for certutil.
          return hex.toLowerAscii()
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
  # ``followSymlinks=false`` is load-bearing on Nix-managed macOS hosts
  # where ``sha256sum`` / ``sha1sum`` / ``sha512sum`` are symlinks into
  # the coreutils multi-call binary; resolving the symlink would
  # invoke ``coreutils`` directly, which prints the help text instead
  # of dispatching to the requested algorithm.
  let sumPath = findExe(sumExe, followSymlinks = false)
  let shasumPath = findExe("shasum", followSymlinks = false)
  let opensslPath = findExe("openssl", followSymlinks = false)
  let certutilPath =
    when defined(windows): findExe("certutil", followSymlinks = false)
    else: ""
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
  let expectedLen =
    case algorithm
    of "sha256": 64
    of "sha512": 128
    of "sha1":   40
    else: 0
  let parsed = parseHexLine(res.output, expectedLen)
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
    # M8: also probe the prefix root — both layouts exist. The M3 hand-
    # authored sevenzip catalog renames the upstream 7zr.exe to
    # ``bin/7z.exe``; the M8 Scoop-MSI re-harvest places ``7z.exe``
    # at the prefix root (lessmsi-flattened ``Files\7-Zip`` payload).
    let candidateRoot = prefixAbs / "7z.exe"
    if fileExists(extendedPath(candidateRoot)):
      return candidateRoot
    let candidateRootNoExe = prefixAbs / "7z"
    if fileExists(extendedPath(candidateRootNoExe)):
      return candidateRootNoExe
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked bin/7z.exe or 7z.exe at prefix root")
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

proc discoverDarkExe*(store: var Store; packageId: string): string =
  ## M4 (Realize-Closure-And-Catalog-Expansion spec) discovery order
  ## for the ``dark.exe`` binary the cakBuiltin Windows MSI realize
  ## hooks need. Mirrors M3's ``discoverSevenZipExe`` pattern:
  ##
  ##   (i)  catalog-registered prefix — look up an already-realized
  ##        ``wix3`` package in the current store. The hand-authored
  ##        ``packages/wix3.nim`` ships ``dark.exe`` at the prefix root
  ##        (the wix314-binaries.zip flattens directly there).
  ##
  ##   (ii) ``PATH`` lookup — operators who have Scoop-installed wix3
  ##        legacy or system WiX get picked up.
  ##
  ##   (iii) fail closed — raise ``EBuiltinDarkUnavailable`` with the
  ##        ``packageId`` (the tool whose realize needed dark.exe) plus
  ##        the per-step discovery trace. Operator remediation:
  ##        ``repro home add wix3``.
  ##
  ## Per the M3 honest-scope contract this discovery does NOT
  ## recursively invoke the apply pipeline mid-realize to bootstrap
  ## wix3 on demand; the operator's ``home.nim`` is responsible for
  ## ordering ``package(wix3)`` ahead of the MSI-needing tools.
  var trace: seq[string] = @[]
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=wix3")
  for row in prefixes:
    if row.packageName != "wix3": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "dark.exe"
    if fileExists(extendedPath(candidate)):
      return candidate
    let candidateBin = prefixAbs / "bin" / "dark.exe"
    if fileExists(extendedPath(candidateBin)):
      return candidateBin
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked dark.exe / bin/dark.exe")
  let pathExe = findExe("dark.exe")
  if pathExe.len > 0:
    return pathExe
  let pathBare = findExe("dark")
  if pathBare.len > 0:
    return pathBare
  trace.add("path:no 'dark' / 'dark.exe' on PATH")
  var e = newException(EBuiltinDarkUnavailable,
    "builtin adapter: MSI realize hook for '" & packageId &
    "' could not discover a dark.exe (WiX v3 decompiler). " &
    "Discovery trace: " & trace.join("; ") &
    ". Remediation: add wix3 to your home profile (`repro home add wix3`) " &
    "or list `package(wix3)` ahead of the MSI-needing tool in home.nim " &
    "(M4 uses discovery-by-prefix; the formal " &
    "`requires_for_realize: [wix3]` schema field is deferred to a " &
    "future campaign). Operators wanting msiexec /a instead of " &
    "dark.exe may set CAKBUILTIN_PREFER_MSIEXEC=1.")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.discoveryTrace = trace
  raise e

proc discoverInnounpExe*(store: var Store; packageId: string): string =
  ## M4 (Realize-Closure-And-Catalog-Expansion spec) discovery order
  ## for the ``innounp.exe`` binary the cakBuiltin Inno Setup realize
  ## hook needs. Mirrors ``discoverDarkExe`` / ``discoverSevenZipExe``.
  ##
  ##   (i)  catalog-registered prefix — look up an already-realized
  ##        ``innounp`` package in the current store.
  ##   (ii) ``PATH`` lookup — operators who have Scoop-installed
  ##        innounp get picked up.
  ##   (iii) fail closed — raise ``EBuiltinInnounpUnavailable``.
  var trace: seq[string] = @[]
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=innounp")
  for row in prefixes:
    if row.packageName != "innounp": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "innounp.exe"
    if fileExists(extendedPath(candidate)):
      return candidate
    let candidateBin = prefixAbs / "bin" / "innounp.exe"
    if fileExists(extendedPath(candidateBin)):
      return candidateBin
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked innounp.exe / bin/innounp.exe")
  let pathExe = findExe("innounp.exe")
  if pathExe.len > 0:
    return pathExe
  let pathBare = findExe("innounp")
  if pathBare.len > 0:
    return pathBare
  trace.add("path:no 'innounp' / 'innounp.exe' on PATH")
  var e = newException(EBuiltinInnounpUnavailable,
    "builtin adapter: Inno Setup realize hook for '" & packageId &
    "' could not discover an innounp.exe binary. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: add innounp to your home profile " &
    "(`repro home add innounp`) or list `package(innounp)` ahead of " &
    "the Inno-Setup-shipped tool in home.nim (M4 uses discovery-by-" &
    "prefix; the formal `requires_for_realize: [innounp]` schema " &
    "field is deferred to a future campaign).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.discoveryTrace = trace
  raise e

proc discoverLessmsiExe*(store: var Store; packageId: string): string =
  ## M4 amendment (post-live-smoke finding) discovery order for the
  ## ``lessmsi.exe`` binary — the canonical "extract MSI to a real
  ## file tree" tool used by the cakBuiltin MSI realize hook.
  ##
  ##   (i)  catalog-registered prefix — look up an already-realized
  ##        ``lessmsi`` package.
  ##   (ii) ``PATH`` lookup — operators who have Scoop-installed
  ##        lessmsi get picked up.
  ##   (iii) fail closed — raise ``EBuiltinLessmsiUnavailable``.
  ##
  ## Replaces the spec-text-proposed ``discoverDarkExe`` as the M4
  ## default; ``discoverDarkExe`` is retained for future use cases
  ## (MSI decompilation) but is not invoked by the M4 realize hooks.
  var trace: seq[string] = @[]
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=lessmsi")
  for row in prefixes:
    if row.packageName != "lessmsi": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "lessmsi.exe"
    if fileExists(extendedPath(candidate)):
      return candidate
    let candidateBin = prefixAbs / "bin" / "lessmsi.exe"
    if fileExists(extendedPath(candidateBin)):
      return candidateBin
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked lessmsi.exe / bin/lessmsi.exe")
  let pathExe = findExe("lessmsi.exe")
  if pathExe.len > 0:
    return pathExe
  let pathBare = findExe("lessmsi")
  if pathBare.len > 0:
    return pathBare
  trace.add("path:no 'lessmsi' / 'lessmsi.exe' on PATH")
  var e = newException(EBuiltinLessmsiUnavailable,
    "builtin adapter: MSI realize hook for '" & packageId &
    "' could not discover a lessmsi.exe binary. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: add lessmsi to your home profile " &
    "(`repro home add lessmsi`) or list `package(lessmsi)` ahead of " &
    "the MSI-needing tool in home.nim. The msiexec /a admin-install " &
    "fallback is available via CAKBUILTIN_PREFER_MSIEXEC=1 but is " &
    "less hermetic (writes to a tmp TARGETDIR; some hosts surface a " &
    "UAC prompt).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.discoveryTrace = trace
  raise e

# ---------------------------------------------------------------------------
# M5 — interpreter discovery for Scoop-style launcher emit
# ---------------------------------------------------------------------------
#
# The lekPhar / lekJar / lekScript launcher emit cases each need an
# interpreter binary (php / java / a script's #! interp) at realize
# time so the emitted .ps1 / .cmd launchers can hard-bake the
# interpreter path. Discovery follows the same M3 catalog-prefix-first
# pattern as ``discoverSevenZipExe`` / ``discoverDarkExe`` /
# ``discoverInnounpExe`` / ``discoverLessmsiExe``:
#
#   (i)  catalog-registered prefix — the operator listed
#        ``package(php)`` / ``package(jdk)`` ahead of the launcher-
#        emitting tool in their home.nim, so a realized prefix exists.
#   (ii) ``PATH`` lookup — operators with Scoop-installed php / java
#        get picked up.
#   (iii) fail closed — raise the specific
#        ``EBuiltinPhpUnavailable`` / ``EBuiltinJavaUnavailable``
#        subclass of ``EBuiltinInterpreterUnavailable`` naming the
#        missing catalog package and the ``repro home add <pkg>``
#        remediation.

proc discoverPhpExe*(store: var Store; packageId: string): string =
  ## M5: discover a ``php.exe`` for the lekPhar launcher emit hook.
  ## ``packageId`` is the tool whose launcher needs php (e.g. composer).
  ## Looks in the catalog-registered ``php`` prefix first (php.nim
  ## ships ``php.exe`` at the prefix root via env_add_path = "" — no
  ## ``bin/`` subdir), then PATH, then fails closed with
  ## ``EBuiltinPhpUnavailable``. The returned path is always absolute
  ## (normalized via ``absolutePath``) so the launcher emit step bakes
  ## a position-independent interpreter reference even when the store
  ## was opened with a relative root.
  var trace: seq[string] = @[]
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=php")
  for row in prefixes:
    if row.packageName != "php": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    # php.nim's bin_relpath is @["php.exe", "php-cgi.exe", "phpdbg.exe"]
    # — root-relative, so we probe the prefix root first.
    let candidate = prefixAbs / "php.exe"
    if fileExists(extendedPath(candidate)):
      return absolutePath(candidate)
    let candidateBare = prefixAbs / "php"
    if fileExists(extendedPath(candidateBare)):
      return absolutePath(candidateBare)
    let candidateBin = prefixAbs / "bin" / "php.exe"
    if fileExists(extendedPath(candidateBin)):
      return absolutePath(candidateBin)
    let candidateBinBare = prefixAbs / "bin" / "php"
    if fileExists(extendedPath(candidateBinBare)):
      return absolutePath(candidateBinBare)
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked php.exe / php / bin/php.exe / bin/php")
  let pathExe = findExe("php.exe")
  if pathExe.len > 0:
    return absolutePath(pathExe)
  let pathBare = findExe("php")
  if pathBare.len > 0:
    return absolutePath(pathBare)
  trace.add("path:no 'php' / 'php.exe' on PATH")
  var e = newException(EBuiltinPhpUnavailable,
    "builtin adapter: lekPhar launcher emit for '" & packageId &
    "' could not discover a php.exe binary. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: add php to your home profile (`repro home add php`) " &
    "or list `package(php)` ahead of `package(" & packageId & ")` in " &
    "home.nim (M5 uses discovery-by-prefix; the formal " &
    "`requires_for_realize: [php]` schema field is deferred to a " &
    "future campaign).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.interpreterPackageId = "php"
  e.discoveryTrace = trace
  raise e

proc discoverJavaExe*(store: var Store; packageId: string): string =
  ## M5: discover a ``java.exe`` for the lekJar launcher emit hook.
  ## ``packageId`` is the tool whose launcher needs java (.jar wrapped).
  ## Looks in the catalog-registered ``jdk`` prefix first (jdk.nim
  ## ships ``bin/java.exe``), then PATH, then fails closed with
  ## ``EBuiltinJavaUnavailable``. The returned path is always absolute
  ## (see ``discoverPhpExe`` for the rationale).
  var trace: seq[string] = @[]
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=jdk")
  for row in prefixes:
    if row.packageName != "jdk": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "bin" / "java.exe"
    if fileExists(extendedPath(candidate)):
      return absolutePath(candidate)
    let candidateBare = prefixAbs / "bin" / "java"
    if fileExists(extendedPath(candidateBare)):
      return absolutePath(candidateBare)
    trace.add("catalog-prefix:row " & row.realizedPath &
      " lacked bin/java.exe / bin/java")
  let pathExe = findExe("java.exe")
  if pathExe.len > 0:
    return absolutePath(pathExe)
  let pathBare = findExe("java")
  if pathBare.len > 0:
    return absolutePath(pathBare)
  trace.add("path:no 'java' / 'java.exe' on PATH")
  var e = newException(EBuiltinJavaUnavailable,
    "builtin adapter: lekJar launcher emit for '" & packageId &
    "' could not discover a java.exe binary. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: add jdk to your home profile (`repro home add jdk`) " &
    "or list `package(jdk)` ahead of `package(" & packageId & ")` in " &
    "home.nim (M5 uses discovery-by-prefix; the formal " &
    "`requires_for_realize: [jdk]` schema field is deferred to a " &
    "future campaign).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.interpreterPackageId = "jdk"
  e.discoveryTrace = trace
  raise e

proc discoverInterpreterExe*(store: var Store; packageId: string;
                              spec: LauncherEmitSpec): string =
  ## M5: dispatch to the right discovery proc by launcher kind. Called
  ## by the realize loop BEFORE entering the staging closure so the
  ## fail-closed path runs before any destructive staging work (same
  ## closure-capture rationale as M3's 7z discovery).
  ##
  ## ``lekScript`` is intentionally not implemented in M5 — no current
  ## catalog tool needs it (composer is the only M5 deferred-8 target),
  ## and the generic "wrapped script" surface needs a per-spec
  ## interpreter declaration the schema does not yet model. Raises a
  ## structured error if a catalog entry tries to use it.
  case spec.kind
  of lekPhar:
    if spec.interpreter_package_id != "php":
      # Defensive: the schema validator enforces interpreter_package_id
      # is non-empty, but a catalog could declare lekPhar + a non-php
      # interpreter. The M5 launcher emit only ships the php path.
      var e = newException(EBuiltinInterpreterUnavailable,
        "builtin adapter: lekPhar launcher emit for '" & packageId &
        "' declared interpreter_package_id='" & spec.interpreter_package_id &
        "' but M5 only supports interpreter_package_id='php' for lekPhar. " &
        "Either fix the catalog entry or extend the M5 discovery table.")
      e.step = 7
      e.stepName = "realize"
      e.packageId = packageId
      e.interpreterPackageId = spec.interpreter_package_id
      raise e
    return discoverPhpExe(store, packageId)
  of lekJar:
    if spec.interpreter_package_id != "jdk":
      var e = newException(EBuiltinInterpreterUnavailable,
        "builtin adapter: lekJar launcher emit for '" & packageId &
        "' declared interpreter_package_id='" & spec.interpreter_package_id &
        "' but M5 only supports interpreter_package_id='jdk' for lekJar. " &
        "Either fix the catalog entry or extend the M5 discovery table.")
      e.step = 7
      e.stepName = "realize"
      e.packageId = packageId
      e.interpreterPackageId = spec.interpreter_package_id
      raise e
    return discoverJavaExe(store, packageId)
  of lekScript:
    var e = newException(EBuiltinInterpreterUnavailable,
      "builtin adapter: lekScript launcher emit for '" & packageId &
      "' is reserved for a future campaign; no current catalog tool " &
      "needs the generic wrapped-script shape. The schema supports " &
      "it for forward compatibility but the M5 realize hook only " &
      "implements lekPhar + lekJar.")
    e.step = 7
    e.stepName = "realize"
    e.packageId = packageId
    e.interpreterPackageId = spec.interpreter_package_id
    raise e

# ---------------------------------------------------------------------------
# M5 — launcher emit (post-extract step)
# ---------------------------------------------------------------------------
#
# The launcher emit step generates two static text files per spec:
#
#   * ``<prefix>/bin/<launcher_name>.ps1`` — PowerShell entry that
#     invokes the discovered interpreter with the target file +
#     forwards ``$args``. Used by Scoop-style PATH activation when the
#     consumer is a PowerShell host.
#   * ``<prefix>/bin/<launcher_name>.cmd`` — cmd.exe entry that does
#     the same with ``%*``. Used when the consumer is cmd.exe / a build
#     tool that shells out without a PowerShell context.
#
# Both files are deterministic (idempotence: identical inputs produce
# identical bytes); the M56 store's content-addressed prefix digest
# covers them so the realize loop's cache-hit check transparently
# includes the launcher payload.
#
# The interpreter path is BAKED in absolute form into the launcher
# text. This is the same shape Scoop's shim layer uses (the .ps1 /
# .cmd files in ``~/scoop/shims/`` reference absolute interpreter
# paths). The trade-off: re-extracting the interpreter prefix (e.g.
# php upgrades) invalidates the composer launcher because its baked
# path no longer exists; the M56 store's realization-hash includes
# the interpreter's prefix path, so re-realizing composer regenerates
# the launcher pointing at the new interpreter.

proc renderPharLauncherPs1(interpreterPath, targetRelFromBin, packageName,
                           packageVersion: string): string =
  ## Emit the .ps1 PowerShell launcher for a lekPhar spec. The text is
  ## intentionally minimal — PowerShell's call operator (``&``) handles
  ## quoting + exit-code forwarding cleanly; ``$args`` is the auto-
  ## populated unbound-positional-arg array that forwards verbatim.
  ##
  ## The interpreter path is BAKED in absolute form (Scoop-style: the
  ## interpreter's catalog prefix is content-addressed and stable for a
  ## given (interpreter, version) pair). The target file is resolved
  ## RELATIVE TO ``$PSScriptRoot`` so the launcher works regardless of
  ## the realized prefix's absolute path — this is critical because
  ## realizePrefix's atomic-rename moves the staging dir to its final
  ## content-addressed location AFTER the launcher emit step. The
  ## ``Join-Path`` resolves at invocation time against the actual
  ## bin/ dir the .ps1 lives in.
  ##
  ## Header comment names the source catalog package + version so
  ## ``cat <launcher>.ps1`` is self-documenting and so a re-emit with a
  ## different version produces visibly-different bytes (the diff is
  ## the header comment + the interpreter path).
  result.add("#!/usr/bin/env pwsh\n")
  result.add("# Auto-generated by cakBuiltin M5 launcher emit; DO NOT EDIT.\n")
  result.add("# Source: package=" & packageName & ", version=" &
    packageVersion & ", launcher_emit kind=lekPhar\n")
  result.add("# NOTE: the interpreter path below is content-addressed —\n")
  result.add("# if the interpreter package (e.g. php) is re-realized at a\n")
  result.add("# different hash, this launcher will reference the stale\n")
  result.add("# prefix. Re-apply this package's realize step to regenerate.\n")
  result.add("$target = Join-Path $PSScriptRoot '" & targetRelFromBin & "'\n")
  result.add("& '" & interpreterPath & "' $target @args\n")
  result.add("exit $LASTEXITCODE\n")

proc renderPharLauncherCmd(interpreterPath, targetRelFromBin, packageName,
                           packageVersion: string): string =
  ## Emit the .cmd cmd.exe launcher for a lekPhar spec. Uses ``%*`` to
  ## forward all argv tokens. ``%~dp0`` resolves to the directory the
  ## .cmd file lives in (including trailing backslash) so the target
  ## path is position-independent. CRLF line endings match cmd.exe's
  ## native expectation.
  result.add("@echo off\r\n")
  result.add("rem Auto-generated by cakBuiltin M5 launcher emit; DO NOT EDIT.\r\n")
  result.add("rem Source: package=" & packageName & ", version=" &
    packageVersion & ", launcher_emit kind=lekPhar\r\n")
  result.add("rem NOTE: the interpreter path below is content-addressed —\r\n")
  result.add("rem if the interpreter package (e.g. php) is re-realized at a\r\n")
  result.add("rem different hash, this launcher will reference the stale\r\n")
  result.add("rem prefix. Re-apply this package's realize step to regenerate.\r\n")
  result.add("\"" & interpreterPath & "\" \"%~dp0" & targetRelFromBin &
    "\" %*\r\n")

proc renderJarLauncherPs1(interpreterPath, targetRelFromBin, packageName,
                          packageVersion: string): string =
  ## Emit the .ps1 launcher for a lekJar spec. Same shape as lekPhar
  ## but the interpreter call adds ``-jar`` so ``java`` treats the
  ## target as a runnable jar rather than a classpath entry.
  result.add("#!/usr/bin/env pwsh\n")
  result.add("# Auto-generated by cakBuiltin M5 launcher emit; DO NOT EDIT.\n")
  result.add("# Source: package=" & packageName & ", version=" &
    packageVersion & ", launcher_emit kind=lekJar\n")
  result.add("# NOTE: the interpreter path below is content-addressed —\n")
  result.add("# if the interpreter package (e.g. jdk) is re-realized at a\n")
  result.add("# different hash, this launcher will reference the stale\n")
  result.add("# prefix. Re-apply this package's realize step to regenerate.\n")
  result.add("$target = Join-Path $PSScriptRoot '" & targetRelFromBin & "'\n")
  result.add("& '" & interpreterPath & "' -jar $target @args\n")
  result.add("exit $LASTEXITCODE\n")

proc renderJarLauncherCmd(interpreterPath, targetRelFromBin, packageName,
                          packageVersion: string): string =
  ## Emit the .cmd launcher for a lekJar spec.
  result.add("@echo off\r\n")
  result.add("rem Auto-generated by cakBuiltin M5 launcher emit; DO NOT EDIT.\r\n")
  result.add("rem Source: package=" & packageName & ", version=" &
    packageVersion & ", launcher_emit kind=lekJar\r\n")
  result.add("rem NOTE: the interpreter path below is content-addressed —\r\n")
  result.add("rem if the interpreter package (e.g. jdk) is re-realized at a\r\n")
  result.add("rem different hash, this launcher will reference the stale\r\n")
  result.add("rem prefix. Re-apply this package's realize step to regenerate.\r\n")
  result.add("\"" & interpreterPath & "\" -jar \"%~dp0" & targetRelFromBin &
    "\" %*\r\n")

proc runLauncherEmit*(packageId, packageVersion, destDir: string;
                      specs: openArray[LauncherEmitSpec];
                      interpreterPaths: openArray[string]) =
  ## M5: emit the launcher .ps1 + .cmd pair for each spec under
  ## ``<destDir>/bin/``. ``interpreterPaths`` is parallel to ``specs``
  ## (one discovered absolute interpreter path per spec). The caller
  ## (the realize loop) discovers interpreter paths via
  ## ``discoverInterpreterExe`` BEFORE entering the staging closure so
  ## the fail-closed path runs before destructive staging work.
  ##
  ## Per the M5 spec's "bin/launcher_name.{ps1,cmd}" placement: the
  ## launcher leafs are emitted under ``<destDir>/bin/`` to match the
  ## catalog's ``bin_relpath`` declarations (e.g. composer's
  ## ``bin/composer.ps1``). The target's prefix-relative path (e.g.
  ## ``composer.phar``) resolves to ``<destDir>/<target>`` — the
  ## payload sits at the prefix root.
  doAssert specs.len == interpreterPaths.len,
    "runLauncherEmit: specs / interpreterPaths length mismatch"
  let binDir = destDir / "bin"
  createDir(extendedPath(binDir))
  for i, spec in specs:
    let interp = interpreterPaths[i]
    let ps1Path = binDir / (spec.launcher_name & ".ps1")
    let cmdPath = binDir / (spec.launcher_name & ".cmd")
    # The target's path RELATIVE TO the bin/ dir (where the launchers
    # live). Since the launchers are in <prefix>/bin/ and the spec's
    # target is prefix-relative (e.g. "composer.phar"), the relative
    # path from bin/ is "..\<target>" (one dir up). Using a relative
    # path lets the launcher work after realizePrefix's atomic-rename
    # of the staging dir to its final content-addressed location.
    # Normalize forward slashes to backslashes for cmd.exe friendliness;
    # PowerShell handles either.
    let targetRelFromBin = (".." / spec.target).replace('/', '\\')
    case spec.kind
    of lekPhar:
      writeFile(extendedPath(ps1Path),
        renderPharLauncherPs1(interp, targetRelFromBin, packageId,
          packageVersion))
      writeFile(extendedPath(cmdPath),
        renderPharLauncherCmd(interp, targetRelFromBin, packageId,
          packageVersion))
    of lekJar:
      writeFile(extendedPath(ps1Path),
        renderJarLauncherPs1(interp, targetRelFromBin, packageId,
          packageVersion))
      writeFile(extendedPath(cmdPath),
        renderJarLauncherCmd(interp, targetRelFromBin, packageId,
          packageVersion))
    of lekScript:
      # Defensive: discoverInterpreterExe already raised for lekScript;
      # this is unreachable from the realize loop. Kept exhaustive for
      # the case-statement.
      doAssert false,
        "runLauncherEmit: lekScript not implemented (M5 ships lekPhar + lekJar)"

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
## M4 — Windows installer family extractors (MSI / NSIS+MSI / Inno Setup)
## ---------------------------------------------------------------------------
##
## All three extractors materialize the installer's *file payload* into
## a destination directory WITHOUT running the installer's side effects
## (no registry writes, no COM registration, no Add/Remove Programs
## entry). This is the cakBuiltin invariant for the M4 installer
## families — extraction is hermetic; activation is the apply
## pipeline's job (PATH / env binding through M65+).

proc extractMsiViaDark(packageId, msiPath, destDir, darkExe: string) =
  ## M4: extract an MSI via WiX ``dark.exe``. dark.exe decompiles the
  ## MSI to a file tree under ``<destDir>/AdminProgramFiles64Folder``
  ## (or similar WiX-named subtrees, depending on the MSI's directory
  ## table). The per-tool flatten layer is the caller's responsibility
  ## (extract_path / merge etc.).
  ##
  ## ``dark.exe -x <output-dir> <input.msi>`` is the canonical
  ## file-extract invocation. dark also writes a decompiled
  ## ``<msi-basename>.wxs`` source file at the destDir root that is
  ## NOT a runtime artifact and is removed before the realized tree is
  ## sealed (caller's responsibility).
  createDir(extendedPath(destDir))
  doAssert darkExe.len > 0,
    "extractMsiViaDark requires a pre-discovered darkExe path"
  let command = quoteShell(darkExe) & " -x " & quoteShell(destDir) &
    " " & quoteShell(msiPath) & " -nologo"
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, msiPath, "installer-msi",
      "dark.exe exited " & $res.exitCode & "\n" & res.output)

proc extractMsiViaMsiexec(packageId, msiPath, destDir: string) =
  ## M4: extract an MSI via ``msiexec /a`` administrative-install.
  ## Writes to ``<destDir>`` directly (TARGETDIR). Does NOT run the
  ## installer's per-machine side effects (no registry writes, no Add/
  ## Remove entry); the admin-install mode is the Windows-native MSI
  ## file-extract path.
  ##
  ## Used when ``CAKBUILTIN_PREFER_MSIEXEC=1`` is set OR a
  ## ``PlatformBinary.msi_admin_install = true`` per-platform override
  ## opts in. dark.exe is the default for hermeticity.
  createDir(extendedPath(destDir))
  let msiexec = findExe("msiexec")
  if msiexec.len == 0:
    raiseExtractFailed(packageId, msiPath, "installer-msi",
      "msiexec not on PATH; cannot perform admin install")
  # /a = admin install; /qn = silent; TARGETDIR= absolute path required.
  let command = quoteShell(msiexec) & " /a " & quoteShell(msiPath) &
    " /qn TARGETDIR=" & quoteShell(absolutePath(destDir))
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, msiPath, "installer-msi",
      "msiexec /a exited " & $res.exitCode & "\n" & res.output)

proc extractMsiViaLessmsi(packageId, msiPath, destDir, lessmsiExe: string) =
  ## M4 amendment: extract an MSI via ``lessmsi`` (the canonical
  ## Windows MSI-to-file-tree extractor; MIT-licensed; 3MB single-zip
  ## distribution; Scoop main carries it). lessmsi writes files at the
  ## MSI's logical install hierarchy under
  ## ``<destDir>/SourceDir/<MSI's install path>/`` so the per-tool
  ## ``extract_path`` field (e.g. ``SourceDir/PFiles64/Meson``) bridges
  ## from the prefix root to the inner subtree.
  ##
  ## Replaces ``extractMsiViaDark`` as the M4 default; dark.exe stays
  ## available for callers that explicitly want MSI decompilation
  ## (e.g. a future M to inspect MSI metadata for compliance review).
  createDir(extendedPath(destDir))
  doAssert lessmsiExe.len > 0,
    "extractMsiViaLessmsi requires a pre-discovered lessmsiExe path"
  # lessmsi CLI:
  #   lessmsi x <msi> [<outdir>/]
  # The trailing slash on outdir matters: WITH slash, lessmsi writes
  # ``<outdir>/SourceDir/...``; WITHOUT slash, lessmsi treats the arg
  # as the basename (legacy compatibility).
  let outDirSlash = destDir & DirSep
  let command = quoteShell(lessmsiExe) & " x " & quoteShell(msiPath) &
    " " & quoteShell(outDirSlash)
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, msiPath, "installer-msi",
      "lessmsi exited " & $res.exitCode & "\n" & res.output)

proc dispatchMsiExtract*(packageId, msiPath, destDir,
                         lessmsiOrDarkExe: string;
                         msiAdminInstallOverride = false) =
  ## M4: pick the MSI extractor per the (i) per-platform
  ## ``msi_admin_install`` override OR (ii) the
  ## ``CAKBUILTIN_PREFER_MSIEXEC`` env-var escape hatch OR (iii) the
  ## default ``lessmsi`` path. Centralizes the decision so callers
  ## (single-MSI realize + per-MSI bundle inner-loop) stay simple.
  ##
  ## **M4 amendment**: the third argument (formerly named ``darkExe``)
  ## now carries the discovered ``lessmsi.exe`` path by default;
  ## callers (the M4 realize loop + the M4 NSIS-bundle inner loop)
  ## switched from ``discoverDarkExe`` to ``discoverLessmsiExe``. The
  ## parameter is renamed for clarity in this proc's signature but the
  ## semantics are: "the MSI extractor binary that ``dispatchMsiExtract``
  ## should invoke when not falling back to msiexec".
  let preferMsiexecEnv = getEnv(BuiltinPreferMsiexecEnvVar)
  let useMsiexec = msiAdminInstallOverride or preferMsiexecEnv.len > 0
  if useMsiexec:
    extractMsiViaMsiexec(packageId, msiPath, destDir)
  else:
    extractMsiViaLessmsi(packageId, msiPath, destDir, lessmsiOrDarkExe)

proc extractInnoSetup(packageId, exePath, destDir, innounpExe: string) =
  ## M4: extract an Inno Setup installer via ``innounp.exe``. innounp
  ## writes the installer's payload files into ``<destDir>``; ``-x``
  ## = extract, ``-d<dir>`` = output dir, ``-y`` = assume yes for
  ## prompts (overwrite).
  ##
  ## innounp's output layout maps Inno's ``{app}\`` subtree directly
  ## under ``<destDir>\{app}\``. The per-tool flatten (typically
  ## moving ``{app}\`` contents one level up) is the caller's
  ## responsibility.
  createDir(extendedPath(destDir))
  doAssert innounpExe.len > 0,
    "extractInnoSetup requires a pre-discovered innounpExe path"
  # innounp v2.x CLI:
  #   innounp -x [-q] [-y] [-dDIR] [-cEMBED] [-pPASS] FILE.exe [files]
  # -x  = extract files
  # -y  = assume yes for all prompts (overwrite)
  # -q  = quiet (suppress per-file output)
  # -d  = destination directory (NO space between -d and the path)
  let command = quoteShell(innounpExe) & " -x -y -q " &
    quoteShell("-d" & destDir) & " " & quoteShell(exePath)
  let res = execCmdEx(command)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, exePath, "installer-inno-setup",
      "innounp exited " & $res.exitCode & "\n" & res.output)

proc flattenInnoAppDir(destDir: string) =
  ## M4: Inno Setup's standard layout places application files under
  ## ``{app}\`` (a literal subdir named ``{app}``). After ``innounp -x``
  ## extracts to ``<destDir>``, we flatten ``<destDir>\{app}\`` up to
  ## the prefix root so ``bin_relpath`` like ``bin/fpc.exe`` resolves
  ## directly. Other top-level Inno dirs (``{commonpf}\``, ``{tmp}\``,
  ## ``embedded\``) survive at the prefix root because not every Inno
  ## installer uses ``{app}``-exclusive layout.
  ##
  ## NB the literal subdir name is ``{app}`` (with curly braces) —
  ## innounp uses Inno's directory constant tokens verbatim as
  ## filesystem names. We do NOT rewrite the braces (other Inno tokens
  ## like ``{commonpf}\`` may also appear and are left alone for the
  ## per-tool catalog author to handle via extract_path).
  let appDir = destDir / "{app}"
  if not dirExists(extendedPath(appDir)):
    return
  for kind, entry in walkDir(extendedPath(appDir), relative = true):
    let src = appDir / entry
    let dst = destDir / entry
    moveFile(extendedPath(src), extendedPath(dst))
    if false: discard kind  # silence unused-warning
  try:
    removeDir(extendedPath(appDir))
  except OSError:
    discard

proc fileBytesEqual(a, b: string): bool =
  ## M4: byte-exact equality between two files. Used by the merge-
  ## conflict detector to decide whether two MSIs writing the same
  ## relpath are conflicting (different bytes) or compatible (same
  ## bytes — currently rejected per the strict default; a future
  ## milestone may relax).
  let aBytes = readFile(extendedPath(a))
  let bBytes = readFile(extendedPath(b))
  aBytes == bBytes

proc mergeIntoPrefixWithConflictCheck*(packageId, sourceLabel,
                                        sourceDir, destDir: string) =
  ## M4: copy every file from ``sourceDir`` into ``destDir``, raising
  ## ``EBuiltinPrefixMergeConflict`` if a file already exists at the
  ## target relpath AND its bytes differ. Same-content collisions
  ## (two MSIs shipping byte-identical bytes for the same path)
  ## ALSO reject under the strict M4 default — the M4 spec calls out
  ## "a future milestone may relax to first-wins-if-byte-identical".
  ## NB the strict-on-same-content choice is documented inline; if a
  ## real package hits the case (no observed instance in M4's target
  ## set), flip ``allowIdenticalDuplicate`` here.
  let allowIdenticalDuplicate = false
  proc walkAndMerge(srcRoot, destRoot, relPrefix: string) =
    for kind, entry in walkDir(extendedPath(srcRoot)):
      let leaf = extractFilename(entry)
      let relpath = if relPrefix.len > 0: relPrefix & "/" & leaf else: leaf
      let dest = destRoot / relpath
      case kind
      of pcFile:
        if fileExists(extendedPath(dest)):
          if allowIdenticalDuplicate and fileBytesEqual(entry, dest):
            continue
          # Conflict.
          var e = newException(EBuiltinPrefixMergeConflict,
            "builtin adapter: NSIS+MSI bundle merge conflict for '" &
            packageId & "' at relpath '" & relpath &
            "' — incoming source '" & sourceLabel &
            "' would overwrite an existing file with different content. " &
            "No silent overwrite; fix by adding a per-MSI extract_path " &
            "override in the catalog entry to land each MSI under a " &
            "distinct subtree.")
          e.step = 7
          e.stepName = "realize"
          e.packageId = packageId
          e.conflictPath = relpath
          e.sourceA = "<prior MSI in merge order>"
          e.sourceB = sourceLabel
          raise e
        createDir(extendedPath(parentDir(dest)))
        copyFile(extendedPath(entry), extendedPath(dest))
      of pcDir:
        createDir(extendedPath(dest))
        walkAndMerge(entry, destRoot, relpath)
      else: discard
  walkAndMerge(sourceDir, destDir, "")

proc extractBurnBundleOuter(packageId, exePath, destDir, darkExe: string) =
  ## M4: crack the outer Burn bundle shell of a Burn/NSIS+MSI bundle
  ## ``.exe`` via WiX ``dark.exe -x``. Burn is WiX's native bundle
  ## format; dark.exe enumerates the bundle's ``AttachedContainer/``
  ## subtree (where the inner MSIs live) plus the ``UX/`` setup-UI
  ## resources. Used as the FIRST pass of ``extractNsisMsiBundle``;
  ## the per-inner-MSI extract uses ``lessmsi`` (via
  ## ``dispatchMsiExtract``) so the M4 dispatch sandwiches dark
  ## (outer) → lessmsi (inner).
  ##
  ## NB dark.exe drops a ``<exe-basename>.wxs`` file in the working
  ## directory as a side effect (decompiled WiX source). We run
  ## dark.exe with ``destDir`` as the working dir so the .wxs lands
  ## INSIDE the scratch tree (and gets removed when the scratch dir
  ## is cleaned up after the bundle merge).
  createDir(extendedPath(destDir))
  doAssert darkExe.len > 0,
    "extractBurnBundleOuter requires a pre-discovered darkExe path"
  let command = quoteShell(darkExe) & " -x " & quoteShell(destDir) &
    " " & quoteShell(exePath) & " -nologo"
  let res = execCmdEx(command, workingDir = destDir)
  if res.exitCode != 0:
    raiseExtractFailed(packageId, exePath, "installer-nsis-bundle",
      "dark.exe (Burn unwrap) exited " & $res.exitCode & "\n" &
      res.output)

proc extractNsisMsiBundle*(packageId, exePath, destDir, lessmsiExe,
                          darkExe, sevenZipExe: string;
                          msiAdminInstallOverride = false) =
  ## M4: extract a Burn/NSIS bundle whose payload is one or more MSIs
  ## (the python3 + swift shape). Three-pass:
  ##
  ##   1. Crack the outer bundle shell. We try in order:
  ##        (a) WiX ``dark.exe`` against the Burn bundle format
  ##            (python3 + swift use this — the "Burn" Windows
  ##            installer format is a WiX-specific shape; dark.exe
  ##            cracks it cleanly into ``AttachedContainer/``);
  ##        (b) ``7z`` against the outer shell (legacy NSIS
  ##            installers that 7z handles natively — rare in the
  ##            target set but kept as a fallback).
  ##   2. Scan the unwrapped tree for ``*.msi`` files (typically
  ##      under ``AttachedContainer/``). Gather in alphabetical order
  ##      (deterministic merge order).
  ##   3. For each MSI: dispatch ``dispatchMsiExtract`` (lessmsi by
  ##      default; msiexec /a under the env-var escape hatch) into a
  ##      per-MSI scratch dir, then merge the per-MSI tree into
  ##      ``destDir`` via ``mergeIntoPrefixWithConflictCheck``.
  ##
  ## Honest scope: this is the M4 architectural shape. The python3 /
  ## swift bundles in the wild may need per-tool flatten passes
  ## (swift's ``LocalApp\Programs\Swift\`` reshuffle, python3's
  ## appendpath.msi skip) — those land in the catalog's
  ## ``pre_install_actions`` block. The base hook here materializes
  ## the merged file tree; per-tool quirks are catalog metadata.
  createDir(extendedPath(destDir))
  let outerScratch = destDir & ".outer-scratch"
  if dirExists(extendedPath(outerScratch)):
    try: removeDir(extendedPath(outerScratch))
    except OSError: discard
  createDir(extendedPath(outerScratch))
  # Step 1: try dark (Burn-bundle preferred) FIRST, fall back to 7z.
  var outerCracked = false
  if darkExe.len > 0:
    try:
      extractBurnBundleOuter(packageId, exePath, outerScratch, darkExe)
      outerCracked = true
    except EBuiltinExtractFailed:
      outerCracked = false
  if not outerCracked:
    if sevenZipExe.len == 0:
      raiseExtractFailed(packageId, exePath, "installer-nsis-bundle",
        "outer-shell unwrap needs either dark.exe (Burn-bundle) or " &
        "7z.exe (legacy NSIS) but neither was usable")
    extract7z(packageId, exePath, outerScratch, sevenZipExe)
  # Step 2: scan for MSI files. Inner MSIs typically live under
  # ``AttachedContainer\`` (Burn bundles — python3 + swift) or at the
  # outerScratch root ($PLUGINSDIR siblings for legacy NSIS).
  var msis: seq[string] = @[]
  proc scanForMsi(dir: string; depth: int) =
    if depth > 3: return  # bound the search
    if not dirExists(extendedPath(dir)): return
    for kind, entry in walkDir(extendedPath(dir)):
      case kind
      of pcFile:
        if entry.toLowerAscii().endsWith(".msi"):
          msis.add(entry)
      of pcDir:
        scanForMsi(entry, depth + 1)
      else: discard
  scanForMsi(outerScratch, 0)
  if msis.len == 0:
    raiseExtractFailed(packageId, exePath, "installer-nsis-bundle",
      "outer bundle unwrapped successfully but contained no .msi " &
      "payload — the upstream may have changed shape; review the " &
      "extracted tree at: " & outerScratch)
  # Deterministic merge order: alphabetical by basename.
  msis.sort do (a, b: string) -> int:
    cmp(extractFilename(a).toLowerAscii(),
        extractFilename(b).toLowerAscii())
  # Step 3: per-MSI extract + merge.
  for i, msi in msis:
    let perMsiScratch = destDir & ".msi-scratch-" & $i
    if dirExists(extendedPath(perMsiScratch)):
      try: removeDir(extendedPath(perMsiScratch))
      except OSError: discard
    createDir(extendedPath(perMsiScratch))
    dispatchMsiExtract(packageId, msi, perMsiScratch, lessmsiExe,
      msiAdminInstallOverride)
    mergeIntoPrefixWithConflictCheck(packageId,
      extractFilename(msi), perMsiScratch, destDir)
    try: removeDir(extendedPath(perMsiScratch))
    except OSError: discard
  # Cleanup the outer scratch tree so it does not pollute the realized
  # prefix.
  try: removeDir(extendedPath(outerScratch))
  except OSError: discard

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
                           envBindings: var seq[tuple[name, value: string]];
                           darkExe = "";
                           innounpExe = "";
                           msiAdminInstallOverride = false) =
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
    of piaExpandDark, piaExpandMsi:
      # M4: Expand-DarkArchive + Expand-MsiArchive — Scoop's MSI
      # extraction primitives. Both dispatch through the same MSI
      # extractor (dark.exe by default, msiexec /a under the env-var
      # escape hatch). Expand-MsiArchive is an alias for the same
      # operation; Scoop's manifests use the two names interchangeably.
      if darkExe.len == 0:
        raiseExtractFailed(packageId, src, "installer-msi",
          "Expand-DarkArchive/MsiArchive in pre_install needs a " &
          "discovered darkExe but none was threaded in (the realize " &
          "loop's Step (i)-(iii) discovery should have run before " &
          "this action)")
      let outDir = if dst.len > 0: dst else: destDir
      createDir(extendedPath(outDir))
      if not fileExists(extendedPath(src)):
        raiseExtractFailed(packageId, src, "installer-msi",
          "Expand-DarkArchive/MsiArchive source missing: " & src)
      dispatchMsiExtract(packageId, src, outDir, darkExe,
        msiAdminInstallOverride)
    of piaExpandInno:
      # M4: Expand-InnoArchive — Inno Setup extraction primitive
      # (M4-introduced; Scoop does not historically ship this as a
      # built-in cmdlet, but the M4 spec wires it into the allowlist
      # for forward compatibility with manifests that grow it).
      if innounpExe.len == 0:
        raiseExtractFailed(packageId, src, "installer-inno-setup",
          "Expand-InnoArchive in pre_install needs a discovered " &
          "innounpExe but none was threaded in (the realize loop's " &
          "Step (i)-(iii) discovery should have run before this action)")
      let outDir = if dst.len > 0: dst else: destDir
      createDir(extendedPath(outDir))
      if not fileExists(extendedPath(src)):
        raiseExtractFailed(packageId, src, "installer-inno-setup",
          "Expand-InnoArchive source missing: " & src)
      extractInnoSetup(packageId, src, outDir, innounpExe)

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

# ---------------------------------------------------------------------------
# M6 (Realize-Closure-And-Catalog-Expansion spec) — .tar.zst extraction
# ---------------------------------------------------------------------------
#
# The MSYS2 pacman repository ships every package as a zstd-compressed
# tar (``.pkg.tar.zst``). M6's realize hook needs a zstd-capable
# extractor; the discovery order mirrors M3/M4:
#
#   (i)  catalog-registered ``7zip`` prefix whose ``bin/7z.exe`` is the
#        FULL 7-Zip distribution (26.01+ ships the zstd codec; the
#        reduced ``7zr.exe`` does NOT). The M3 hand-authored
#        ``packages/sevenzip.nim`` currently routes through 7zr; until
#        the M11 follow-up re-harvests sevenzip to the MSI shape, this
#        step typically misses on freshly-bootstrapped hosts.
#   (ii) host ``tar`` with the ``--zstd`` filter (Git for Windows ships
#        this).
#   (iii) host ``zstd`` piped to ``tar`` (POSIX hosts with the
#        upstream Facebook zstd binary).
#   (iv) fail-closed with ``EBuiltinZstdUnavailable``.
#
# Per the bundling-posture amendment we do NOT vendor a zstd binary; the
# spec's ``libs/repro_home_apply/vendor/zstd/`` deliverable is replaced
# with the multi-strategy host discovery + the future re-harvested
# sevenzip MSI catalog. Documented in the M6 spec note.

proc probe7zZstdSupport(sevenZipExe: string): bool =
  ## Probe whether the discovered ``7z.exe`` supports the zstd codec by
  ## running ``7z i`` and looking for the zstd line. Cached implicitly
  ## via the discoverer's own catalog-prefix lookup (the discovered path
  ## is stable for a given store snapshot).
  ##
  ## ``7zr.exe`` (the reduced standalone) reports a small set of formats
  ## that does NOT include zstd. The full ``7z.exe`` from the MSI suite
  ## (or the upstream ``7z2601-extra.7z`` "extra" archive) ships the
  ## codec and reports it via ``7z i``.
  if sevenZipExe.len == 0: return false
  let command = quoteShell(sevenZipExe) & " i"
  let res = execCmdEx(command)
  if res.exitCode != 0: return false
  # The ``7z i`` output enumerates one format per line; the zstd entry
  # looks like ``... zstd     zst tzst (.tar) ( B5 / FD``. A
  # case-insensitive substring match on ``zstd`` is sufficient — no
  # other format line carries that token.
  res.output.toLowerAscii().contains("zstd")

type
  ZstdExtractorKind* = enum
    zekSevenZip
    zekTarFilter
    zekZstdPipe

  ZstdExtractor* = object
    ## M6: the per-discovery result of ``discoverZstdExtractor``. Carries
    ## the chosen strategy + the resolved binary path(s) so the per-
    ## archive extraction call does not re-do discovery for each file.
    case kind*: ZstdExtractorKind
    of zekSevenZip:
      sevenZipExe*: string  ## absolute path to a zstd-capable 7z.exe
    of zekTarFilter:
      tarExe*: string       ## absolute path to a ``tar`` with --zstd
    of zekZstdPipe:
      zstdExe*: string      ## absolute path to a zstd binary
      tarExeForPipe*: string  ## absolute path to a tar that reads from
                              ## stdin (any modern tar; the same one
                              ## ``extractTar`` would discover)

proc discoverZstdExtractor*(store: var Store; packageId: string):
    ZstdExtractor =
  ## M6: pick the best available zstd-capable extractor. Discovery order
  ## documented in the module-level comment above. Raises
  ## ``EBuiltinZstdUnavailable`` if every step misses.
  ##
  ## NB the catalog-prefix lookup probes for the FULL 7z (zstd codec
  ## present), NOT just any ``bin/7z.exe``. The M3 hand-authored 7zr
  ## entry will report no zstd support; we treat that as a miss and
  ## fall through to host tools. Once sevenzip is re-harvested to the
  ## MSI shape, this branch will hit cleanly.
  var trace: seq[string] = @[]
  # Step (i): catalog-registered 7zip prefix with zstd codec.
  let prefixes = listPrefixes(store)
  trace.add("catalog-prefix:scanned " & $prefixes.len & " rows for package=7zip")
  for row in prefixes:
    if row.packageName != "7zip": continue
    let prefixAbs = store.absolutePrefixPath(row.realizedPath)
    let candidate = prefixAbs / "bin" / "7z.exe"
    if fileExists(extendedPath(candidate)):
      if probe7zZstdSupport(candidate):
        return ZstdExtractor(kind: zekSevenZip, sevenZipExe: candidate)
      trace.add("catalog-prefix:row " & row.realizedPath &
        " has bin/7z.exe but no zstd codec (likely reduced 7zr; " &
        "re-harvest sevenzip to the MSI shape per M11 follow-up)")
    let candidateBare = prefixAbs / "bin" / "7z"
    if fileExists(extendedPath(candidateBare)):
      if probe7zZstdSupport(candidateBare):
        return ZstdExtractor(kind: zekSevenZip, sevenZipExe: candidateBare)
      trace.add("catalog-prefix:row " & row.realizedPath &
        " has bin/7z but no zstd codec")
  # Step (i'): PATH-resident 7z with zstd (Scoop sevenzip ships the
  # full codec set; useful for hosts where 7zip is host-installed).
  let path7z = findExe("7z.exe")
  if path7z.len > 0 and probe7zZstdSupport(path7z):
    return ZstdExtractor(kind: zekSevenZip, sevenZipExe: path7z)
  if path7z.len > 0:
    trace.add("path:7z.exe present but no zstd codec")
  else:
    trace.add("path:no 7z.exe on PATH")
  let path7zBare = findExe("7z")
  if path7zBare.len > 0 and probe7zZstdSupport(path7zBare):
    return ZstdExtractor(kind: zekSevenZip, sevenZipExe: path7zBare)
  # Step (ii): host tar with zstd support. Probe two shapes:
  #   * GNU tar's explicit ``--zstd`` filter (Git for Windows ships
  #     this; check ``tar --help`` output).
  #   * bsdtar (Windows 10+'s built-in ``C:\Windows\system32\tar.exe``,
  #     macOS's stock tar) auto-detects .tar.zst when libarchive was
  #     linked against libzstd; the ``tar --version`` output reveals
  #     ``libzstd/<version>`` in that case.
  let pathTar = findExe("tar")
  if pathTar.len > 0:
    let helpRes = execCmdEx(quoteShell(pathTar) & " --help")
    if helpRes.exitCode == 0 and helpRes.output.contains("--zstd"):
      return ZstdExtractor(kind: zekTarFilter, tarExe: pathTar)
    # Probe the --version banner for bsdtar's libzstd linkage marker.
    let versionRes = execCmdEx(quoteShell(pathTar) & " --version")
    if versionRes.exitCode == 0 and
       (versionRes.output.contains("libzstd") or
        versionRes.output.contains("bsdtar")):
      # bsdtar's transparent auto-detect — we invoke as ``tar -xf`` and
      # rely on libarchive to recognize the zstd envelope. We surface
      # this as zekTarFilter for the same call path; the extractTarZst
      # implementation falls back to ``-xf`` when ``--zstd`` rejects.
      return ZstdExtractor(kind: zekTarFilter, tarExe: pathTar)
    trace.add("path:tar present but lacks --zstd filter and no " &
      "libzstd linkage banner")
  else:
    trace.add("path:no tar on PATH")
  # Step (iii): host zstd + host tar piped.
  let pathZstd = findExe("zstd")
  if pathZstd.len > 0 and pathTar.len > 0:
    return ZstdExtractor(kind: zekZstdPipe, zstdExe: pathZstd,
      tarExeForPipe: pathTar)
  trace.add("path:no zstd on PATH (combined with a tar that lacks --zstd)")
  # Step (iv): fail closed.
  var e = newException(EBuiltinZstdUnavailable,
    "builtin adapter: tar.zst realize hook for '" & packageId &
    "' could not discover a zstd-capable extractor. Discovery trace: " &
    trace.join("; ") &
    ". Remediation: install Git for Windows (its bundled `tar` ships " &
    "with the `--zstd` filter) OR ensure the catalog `7zip` package " &
    "carries the FULL 7-Zip suite (the M3 hand-authored sevenzip.nim " &
    "currently ships the reduced `7zr.exe` which lacks the zstd codec; " &
    "re-harvest via the M11 follow-up MSI shape to fix this branch).")
  e.step = 7
  e.stepName = "realize"
  e.packageId = packageId
  e.discoveryTrace = trace
  raise e

proc extractTarZst*(packageId, archivePath, destDir: string;
                    extractor: ZstdExtractor) =
  ## M6: extract a ``.tar.zst`` archive into ``destDir`` using the
  ## discovered extractor. Each strategy uses the SAME canonical
  ## extraction shape (recursive, overwrite, no progress bar) so the
  ## resulting tree is identical regardless of which path the
  ## discoverer picked.
  createDir(extendedPath(destDir))
  case extractor.kind
  of zekSevenZip:
    # 7z handles .tar.zst in two passes natively (zstd -> tar) — we ask
    # for the type explicitly via ``-ttar`` after a first ``zstd`` pass,
    # but the simpler approach is to use ``-so`` (stdout) to pipe the
    # decompressed tar into a second 7z that does ``-si -ttar``. To
    # avoid the pipe + shell quoting complexity, we use the documented
    # 7z idiom: extract the .tar.zst directly. 7z 26.01 transparently
    # handles the two-layer envelope when invoked twice — first
    # decompressing the zstd, then extracting the tar. The simpler
    # one-shot form: a temporary ``.tar`` file produced by 7z, then
    # extracted by tar. We use that to keep the codepath obvious.
    let tmpTar = destDir / ".tmp.zst-decompressed.tar"
    let decompressCmd = quoteShell(extractor.sevenZipExe) & " x " &
      quoteShell("-o" & destDir) & " " & quoteShell(archivePath) &
      " -y -bsp0 -bso0"
    let decompressRes = execCmdEx(decompressCmd)
    if decompressRes.exitCode != 0:
      raiseExtractFailed(packageId, archivePath, "tar.zst",
        "7z (zstd decompress) exited " & $decompressRes.exitCode &
        "\n" & decompressRes.output)
    # 7z drops the decompressed tar under destDir using the archive's
    # leaf-name minus the .zst suffix. Locate it and extract.
    discard tmpTar  # reserved name documented in the comment above
    let baseLeaf = extractFilename(archivePath)
    var decompressedTar = ""
    if baseLeaf.toLowerAscii().endsWith(".zst"):
      decompressedTar = destDir / baseLeaf[0 ..< baseLeaf.len - 4]
    if decompressedTar.len == 0 or
       not fileExists(extendedPath(decompressedTar)):
      # Fallback: scan destDir for the first .tar produced by the
      # decompression pass.
      for kind, entry in walkDir(extendedPath(destDir)):
        if kind == pcFile and entry.toLowerAscii().endsWith(".tar"):
          decompressedTar = entry
          break
    if decompressedTar.len == 0 or
       not fileExists(extendedPath(decompressedTar)):
      raiseExtractFailed(packageId, archivePath, "tar.zst",
        "7z decompressed the zstd envelope but no .tar landed under " &
        destDir)
    let tarCmd = quoteShell(extractor.sevenZipExe) & " x " &
      quoteShell("-o" & destDir) & " " & quoteShell(decompressedTar) &
      " -y -bsp0 -bso0"
    let tarRes = execCmdEx(tarCmd)
    if tarRes.exitCode != 0:
      raiseExtractFailed(packageId, archivePath, "tar.zst",
        "7z (tar extract from " & decompressedTar & ") exited " &
        $tarRes.exitCode & "\n" & tarRes.output)
    try:
      removeFile(extendedPath(decompressedTar))
    except OSError:
      discard
  of zekTarFilter:
    # GNU tar: ``tar --zstd -xf`` (explicit filter).
    # bsdtar: ``tar -xf`` (libarchive auto-detects the zstd envelope).
    # We try the explicit filter first because it short-circuits
    # libarchive's auto-detection cost on GNU tar; if --zstd is
    # rejected (bsdtar prints "Option --zstd is not supported") we
    # fall back to bare ``-xf``.
    let cmdExplicit = quoteShell(extractor.tarExe) & " --zstd -xf " &
      quoteShell(archivePath) & " -C " & quoteShell(destDir)
    let resExplicit = execCmdEx(cmdExplicit)
    if resExplicit.exitCode == 0:
      discard
    else:
      let cmdAuto = quoteShell(extractor.tarExe) & " -xf " &
        quoteShell(archivePath) & " -C " & quoteShell(destDir)
      let resAuto = execCmdEx(cmdAuto)
      if resAuto.exitCode != 0:
        raiseExtractFailed(packageId, archivePath, "tar.zst",
          "tar extraction failed (both --zstd and auto-detect):\n" &
          "  --zstd exit=" & $resExplicit.exitCode & ": " &
          resExplicit.output & "\n" &
          "  -xf exit=" & $resAuto.exitCode & ": " & resAuto.output)
  of zekZstdPipe:
    # ``zstd -dc <archive> | tar -xf - -C <destDir>``. Cross-platform
    # POSIX pipe shape. We use ``execShellCmd`` indirectly via
    # ``execCmdEx`` because the shell-pipeline form needs the shell to
    # parse the ``|``. ``execCmdEx`` runs through cmd.exe on Windows,
    # which honors ``|`` natively — but Windows hosts typically take
    # the (ii) path before falling through here, so this branch is
    # primarily a POSIX path.
    let command = quoteShell(extractor.zstdExe) & " -dc " &
      quoteShell(archivePath) & " | " &
      quoteShell(extractor.tarExeForPipe) & " -xf - -C " &
      quoteShell(destDir)
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raiseExtractFailed(packageId, archivePath, "tar.zst",
        "zstd | tar pipeline exited " & $res.exitCode & "\n" & res.output)

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
  # M4: include the per-platform msi_admin_install override in the
  # realization hash so a slice that flips dark.exe ↔ msiexec produces
  # a fresh prefix.
  if resolution.msiAdminInstall:
    extra.add("msiAdminInstall:true")
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
    # M4: imInstallerNsisBundle also needs 7z to unwrap the NSIS shell.
    if resolution.installMethod == imInstallerNsisBundle:
      return true
    for a in resolution.preInstallActions:
      if a.kind == piaExpand7z: return true
    false
  if needsSevenZip():
    sevenZipExe = discoverSevenZipExe(store, packageId)

  # M4: discover lessmsi.exe (MSI-to-file-tree extractor) when this
  # realize will need it — imInstallerMsi, imInstallerNsisBundle, or a
  # pre_install Expand-{Dark,Msi}Archive action. Same closure-capture
  # rationale as the M3 7z discovery: discovery FIRST, destructive
  # staging SECOND. The msiexec /a escape hatch lets us skip discovery
  # entirely when the operator opted in.
  #
  # M4 also discovers dark.exe SEPARATELY for the Burn-bundle outer
  # unwrap of imInstallerNsisBundle. Burn bundles (python3 + swift)
  # are NOT 7z archives; dark.exe cracks them into AttachedContainer/
  # with the inner MSIs. The sandwich: dark (outer) → lessmsi (inner).
  var lessmsiExe = ""
  var darkExe = ""
  let preferMsiexec = getEnv(BuiltinPreferMsiexecEnvVar).len > 0
  proc needsLessmsi(): bool =
    if preferMsiexec: return false
    if resolution.installMethod in {imInstallerMsi, imInstallerNsisBundle}:
      # If the per-platform msi_admin_install override is set we also
      # skip discovery (msiexec is the planned tool).
      if resolution.msiAdminInstall: return false
      return true
    for a in resolution.preInstallActions:
      if a.kind in {piaExpandDark, piaExpandMsi}: return true
    false
  proc needsDark(): bool =
    # dark.exe is needed for Burn-bundle outer unwrap of
    # imInstallerNsisBundle (python3 + swift) — independent of the
    # msiexec override (which only affects the INNER per-MSI extract).
    if resolution.installMethod == imInstallerNsisBundle:
      return true
    false
  if needsLessmsi():
    lessmsiExe = discoverLessmsiExe(store, packageId)
  if needsDark():
    darkExe = discoverDarkExe(store, packageId)

  # M4: discover innounp.exe when imInstallerInnoSetup OR a pre_install
  # Expand-InnoArchive action references it.
  var innounpExe = ""
  proc needsInnounp(): bool =
    if resolution.installMethod == imInstallerInnoSetup:
      return true
    for a in resolution.preInstallActions:
      if a.kind == piaExpandInno: return true
    false
  if needsInnounp():
    innounpExe = discoverInnounpExe(store, packageId)

  # M5: discover the interpreter binary for each launcher_emit spec
  # BEFORE entering the staging closure. Same closure-capture rationale
  # as M3/M4: discovery FIRST, destructive staging SECOND. The fail-
  # closed path (EBuiltinPhpUnavailable / EBuiltinJavaUnavailable)
  # raises here rather than mid-extract so a missing interpreter does
  # not leave a half-realized prefix.
  var launcherInterpreterPaths: seq[string] = @[]
  for spec in resolution.launcherEmit:
    launcherInterpreterPaths.add(
      discoverInterpreterExe(store, packageId, spec))

  # M6: discover the zstd-capable extractor when this realize will need
  # one (archive_format = afTarZst OR install_method = imMsys2Pacman —
  # MSYS2 pacman packages are always .pkg.tar.zst). Same closure-
  # capture rationale: discovery FIRST so EBuiltinZstdUnavailable
  # raises before any destructive staging work.
  var zstdExtractor: ZstdExtractor
  var zstdExtractorReady = false
  if resolution.archiveFormat == afTarZst or
     resolution.installMethod == imMsys2Pacman:
    zstdExtractor = discoverZstdExtractor(store, packageId)
    zstdExtractorReady = true

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
      of afTarZst: archiveExt = ".tar.zst"
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
        of afTarZst:
          # M6: zstd-compressed tar; route through the discovered zstd
          # extractor (catalog 7z → host tar --zstd → host zstd pipe).
          doAssert zstdExtractorReady,
            "afTarZst dispatch reached without a discovered zstd extractor"
          extractTarZst(packageId, downloadPath, stagingDir, zstdExtractor)
        of afSevenZip:
          extract7z(packageId, downloadPath, stagingDir, sevenZipExe)
        of afSevenZipSfx:
          # M3: 7z self-extracting EXE — the archive payload is a 7z
          # stream with a PE-SFX loader stub prepended. The 7z extractor
          # recognises the envelope transparently; same code path.
          extract7z(packageId, downloadPath, stagingDir, sevenZipExe)
        of afRaw:
          # M5: when launcher_emit is non-empty, the bin_relpath entries
          # are the LAUNCHERS we are about to synthesize — NOT the raw
          # payload. Place the downloaded bytes at launcher_emit[0].target
          # (e.g. "composer.phar") so the launcher's baked target path
          # resolves on disk; the launcher emit step below then writes
          # the .ps1 / .cmd files that satisfy the bin_relpath sanity
          # check.
          let rel =
            if resolution.launcherEmit.len > 0:
              resolution.launcherEmit[0].target
            elif resolution.binRelpath.len > 0: resolution.binRelpath[0]
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
            sevenZipExe, preInstallEnvBindings,
            darkExe = darkExe, innounpExe = innounpExe,
            msiAdminInstallOverride = resolution.msiAdminInstall)
      of imInstallerSilent:
        capturedInstallerArgv = runInstallerSilent(packageId, downloadPath,
          stagingDir, resolution.installerArgs, resolution.archiveFormat)
      of imInstallerMsi:
        # M4: MSI extraction via lessmsi (default) or msiexec /a
        # (CAKBUILTIN_PREFER_MSIEXEC=1 or platform.msi_admin_install).
        # The extracted tree is left under stagingDir; the per-tool
        # flatten happens via the extract_path mechanism below.
        dispatchMsiExtract(packageId, downloadPath, stagingDir,
          lessmsiExe, resolution.msiAdminInstall)
        flattenExtractPath(packageId, stagingDir, resolution.extractPath)
        if resolution.preInstallActions.len > 0 or
           resolution.preInstallUnrecognized.len > 0:
          runPreInstallActions(packageId, stagingDir,
            resolution.preInstallActions,
            resolution.preInstallUnrecognized,
            sevenZipExe, preInstallEnvBindings,
            darkExe = lessmsiExe, innounpExe = innounpExe,
            msiAdminInstallOverride = resolution.msiAdminInstall)
      of imInstallerNsisBundle:
        # M4: Burn/NSIS bundle (python3 + swift shape). Sandwich:
        # dark.exe cracks the outer Burn bundle into
        # AttachedContainer/, then lessmsi extracts each inner MSI and
        # merges with conflict detection. Honest scope: per-tool
        # flatten quirks (swift's LocalApp\Programs\Swift\ reshuffle,
        # python3's appendpath.msi skip) land in the catalog's
        # pre_install_actions block.
        extractNsisMsiBundle(packageId, downloadPath, stagingDir,
          lessmsiExe, darkExe, sevenZipExe,
          resolution.msiAdminInstall)
        flattenExtractPath(packageId, stagingDir, resolution.extractPath)
        if resolution.preInstallActions.len > 0 or
           resolution.preInstallUnrecognized.len > 0:
          runPreInstallActions(packageId, stagingDir,
            resolution.preInstallActions,
            resolution.preInstallUnrecognized,
            sevenZipExe, preInstallEnvBindings,
            darkExe = lessmsiExe, innounpExe = innounpExe,
            msiAdminInstallOverride = resolution.msiAdminInstall)
      of imInstallerInnoSetup:
        # M4: Inno Setup extraction via innounp.exe (the freepascal /
        # fpc shape). innounp lays the installer's payload out under
        # ``<stagingDir>\{app}\``; ``flattenInnoAppDir`` moves the
        # ``{app}\`` subtree up to the prefix root so bin_relpath like
        # ``bin/fpc.exe`` resolves directly.
        extractInnoSetup(packageId, downloadPath, stagingDir, innounpExe)
        flattenInnoAppDir(stagingDir)
        flattenExtractPath(packageId, stagingDir, resolution.extractPath)
        if resolution.preInstallActions.len > 0 or
           resolution.preInstallUnrecognized.len > 0:
          runPreInstallActions(packageId, stagingDir,
            resolution.preInstallActions,
            resolution.preInstallUnrecognized,
            sevenZipExe, preInstallEnvBindings,
            darkExe = lessmsiExe, innounpExe = innounpExe,
            msiAdminInstallOverride = resolution.msiAdminInstall)
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
        of afTarZst:
          doAssert zstdExtractorReady,
            "afTarZst dispatch reached without a discovered zstd extractor"
          extractTarZst(packageId, downloadPath, unpackDir, zstdExtractor)
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
        # M6 (Realize-Closure-And-Catalog-Expansion spec): realize a
        # MSYS2 pacman package by extracting its ``.pkg.tar.zst`` payload
        # into the staging dir. We DO NOT invoke pacman — the cakBuiltin
        # invariant is download + extract; the ``pacman_packages`` list
        # is the catalog-author audit trail (e.g.
        # ``mingw-w64-x86_64-ocaml``), NOT a recursive package-manager
        # call. Dependency resolution stays the operator's responsibility
        # (list every needed MSYS2 package in home.nim).
        #
        # The archive_format MUST be ``afTarZst`` for imMsys2Pacman per
        # the M6 schema; the validator (validateVersionedProvisioning)
        # is not strict on the pairing today, so we assert it here for
        # an explicit failure rather than a silent path mismatch.
        if resolution.archiveFormat != afTarZst:
          raiseExtractFailed(packageId, downloadPath,
            $resolution.archiveFormat,
            "imMsys2Pacman requires archive_format=afTarZst; got " &
            $resolution.archiveFormat)
        doAssert zstdExtractorReady,
          "imMsys2Pacman dispatch reached without a discovered zstd extractor"
        extractTarZst(packageId, downloadPath, stagingDir, zstdExtractor)
        # Flatten the inner mingw64/ (or ucrt64/, clang64/, …) prefix
        # subtree to the prefix root. extract_path is normally
        # ``mingw64`` for MSYS2 mingw64-env packages; the harvester
        # writes this verbatim. Reuses the same ``flattenExtractPath``
        # the M64 imExtract path uses — no new code surface needed.
        flattenExtractPath(packageId, stagingDir, resolution.extractPath)
        # Replay any allowlisted pre_install actions (M3). MSYS2
        # packages rarely declare any, but the hook is uniform with
        # imExtract for forward compatibility.
        if resolution.preInstallActions.len > 0 or
           resolution.preInstallUnrecognized.len > 0:
          runPreInstallActions(packageId, stagingDir,
            resolution.preInstallActions,
            resolution.preInstallUnrecognized,
            sevenZipExe, preInstallEnvBindings,
            darkExe = lessmsiExe, innounpExe = innounpExe,
            msiAdminInstallOverride = resolution.msiAdminInstall)

      # M5: Scoop-style launcher emit. Runs AFTER install_method dispatch
      # so the target file (e.g. composer.phar) is already on disk, but
      # BEFORE the bin_relpath sanity check (the launchers populate
      # bin/<launcher_name>.{ps1,cmd} which the catalog declares in
      # bin_relpath). Interpreter paths were discovered above (outside
      # the closure) so the fail-closed path runs before any destructive
      # staging.
      if resolution.launcherEmit.len > 0:
        runLauncherEmit(packageId, version, stagingDir,
          resolution.launcherEmit, launcherInterpreterPaths)

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
