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
    if hex.len == 64 or hex.len == 128:
      return hex.toLowerAscii()
  ""

proc fileShaHex*(path: string; algorithm: string): string =
  ## Compute the SHA-256 or SHA-512 hex digest of `path`. `algorithm`
  ## ∈ {"sha256", "sha512"}.  Shells out — keeps the realize loop free
  ## of a native hash dependency and matches the existing
  ## `repro_tool_profiles.fileSha256Hex` pattern.
  if algorithm notin ["sha256", "sha512"]:
    raise newException(ValueError,
      "builtin adapter: unsupported digest algorithm '" & algorithm & "'")
  let sumExe =
    if algorithm == "sha256": "sha256sum"
    else: "sha512sum"
  let shasumArg = if algorithm == "sha256": "256" else: "512"
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
      let downloadPath = downloadDir / ("artifact." & $getCurrentProcessId() &
        "." & $getTime().toUnix)
      downloadToFile(resolution.urlUsed, downloadPath, packageId)

      # 2) Verify SHA.
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
          raiseExtractFailed(packageId, downloadPath, "7z",
            "afSevenZip extraction is deferred (no built-in 7z dispatch in M64)")
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
        else:
          raiseExtractFailed(packageId, downloadPath,
            $resolution.archiveFormat,
            "imSourceBootstrap requires an archive format (zip/tar.*)")
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
