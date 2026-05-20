## Test-support helpers shared by the three M55 Scoop adapter gates.
##
## These helpers stand up a sandboxed Scoop root so each E2E test can
## run real `scoop.exe` against a known-good bucket and apps layout
## without touching the user's real Scoop installation. The host's
## existing Scoop install is required (real binary requirement) — but
## $env:SCOOP redirects every state change into the test temp dir.

import std/[json, os, osproc, sequtils, strutils]

import repro_interface_artifacts
import repro_tool_profiles

proc deleteJunctionsRec*(root: string) =
  ## Walks a tree and removes every directory entry that is a junction
  ## reparse point before the caller invokes `removeDir`. Without this
  ## step, Nim's removeDir on Windows recurses into the junction target
  ## and either deletes the target's contents or fails with Access
  ## Denied — neither is acceptable for tests that put a junction
  ## inside a temp dir.
  if not dirExists(root):
    return
  when defined(windows):
    for kind, path in walkDir(root, relative = false):
      case kind
      of pcLinkToDir:
        discard execCmdEx("cmd /c rmdir " & quoteShell(path))
      of pcDir:
        deleteJunctionsRec(path)
      else:
        discard
  else:
    for kind, path in walkDir(root, relative = false):
      if kind == pcLinkToDir:
        removeFile(path)
      elif kind == pcDir:
        deleteJunctionsRec(path)

proc safeRemoveTempRoot*(tempRoot: string) =
  try:
    deleteJunctionsRec(tempRoot)
    removeDir(tempRoot)
  except OSError:
    # Test temp dirs are short-lived; tolerate residual scoop state
    # rather than masking a test failure with a cleanup exception.
    discard

type
  ScoopSandbox* = object
    root*: string                  # <tempRoot>/scoop
    bucketsDir*: string
    appsDir*: string
    bucketName*: string
    bucketDir*: string
    bucketManifestDir*: string

  ScoopFixtureApp* = object
    name*: string
    version*: string
    executableName*: string
    versionDir*: string             # <root>/apps/<app>/<version>
    currentDir*: string             # <root>/apps/<app>/current
    executablePath*: string         # <versionDir>/<exe>
    manifestPath*: string           # <bucketManifestDir>/<app>.json

proc resolveScoopBinary*(): string =
  ## Locate real scoop on PATH. Tests fail closed with a clear diagnostic
  ## if scoop is missing — the M55 spec says we must NOT mock scoop.
  for candidate in @["scoop.cmd", "scoop.ps1", "scoop.exe", "scoop"]:
    let resolved = findExe(candidate)
    if resolved.len > 0:
      return resolved
  ""

proc q*(value: string): string = quoteShell(value)

proc shellCommand*(args: openArray[string]): string =
  args.mapIt(q(it)).join(" ")

proc runShellInRoot*(command: string; cwd = getCurrentDir()):
    tuple[code: int; output: string] =
  let res = execCmdEx(command, workingDir = cwd)
  (code: res.exitCode, output: res.output)

proc writeMinimalManifest*(manifestPath, version, executableName: string;
                           localExecutable: string) =
  ## Write a minimal Scoop manifest that points at a `file://` URL of the
  ## fixture binary so the host Scoop install can resolve the manifest
  ## without needing network access. The adapter under test reads the
  ## manifest by path and computes its own checksum — it does not
  ## re-download.
  let manifest = %*{
    "version": version,
    "description": "Reprobuild M55 fixture app",
    "homepage": "https://github.com/metacraft-labs/reprobuild",
    "license": "MIT",
    "url": "file:///" & localExecutable.replace('\\', '/'),
    "bin": executableName
  }
  createDir(manifestPath.parentDir)
  writeFile(manifestPath, manifest.pretty())

proc writeFixtureExecutable*(targetPath, payload: string) =
  ## Generate a deterministic fixture executable: a Windows batch file
  ## that prints a known version string. Even though the file extension
  ## might be .exe on disk, the adapter resolves through PATH-aware
  ## probing — for the M55 gates we only need the file to exist and be
  ## byte-stable so the execution-profile checksum is reproducible.
  createDir(targetPath.parentDir)
  writeFile(targetPath, payload)

proc setupScoopSandbox*(tempRoot, bucketName: string): ScoopSandbox =
  let root = tempRoot / "scoop"
  result = ScoopSandbox(
    root: root,
    bucketsDir: root / "buckets",
    appsDir: root / "apps",
    bucketName: bucketName,
    bucketDir: root / "buckets" / bucketName,
    bucketManifestDir: root / "buckets" / bucketName / "bucket")
  for dir in @[result.root, result.bucketsDir, result.appsDir,
               result.bucketDir, result.bucketManifestDir,
               root / "cache", root / "shims", root / "persist"]:
    createDir(dir)
  putEnv("SCOOP", result.root)

proc populateScoopApp*(sandbox: ScoopSandbox; app, version, executableName,
                      executablePayload: string): ScoopFixtureApp =
  ## Pre-position an already-installed Scoop app in the sandboxed root.
  ## Mirrors what `scoop install <bucket>/<app>` would lay down: an
  ## exact-version directory plus a `current` junction pointing at it.
  let versionDir = sandbox.appsDir / app / version
  let currentDir = sandbox.appsDir / app / "current"
  let executablePath = versionDir / executableName
  createDir(versionDir)
  writeFixtureExecutable(executablePath, executablePayload)

  # Scoop's per-app install.json — required by `scoop list` to recognize
  # the install as managed.
  let installJson = %*{
    "architecture": "64bit",
    "bucket": sandbox.bucketName
  }
  writeFile(versionDir / "install.json", installJson.pretty())
  # M74: Scoop copies the bucket manifest into the version dir on
  # install; the M74 adapter resolves the executable from this
  # version-dir `manifest.json` `bin` field. A realistic fixture
  # therefore writes a real manifest whose `bin` points at where the
  # fixture executable actually is — here the version ROOT, since
  # `populateScoopApp` places the exe at `<versionDir>/<executableName>`.
  let versionManifest = %*{
    "version": version,
    "description": "Reprobuild M55 fixture app",
    "bin": executableName
  }
  writeFile(versionDir / "manifest.json", versionManifest.pretty())

  # The `current` symlink/junction is what Scoop uses for shims; the
  # M55 adapter must NOT bind through this — it must bind through the
  # exact-version dir.
  if dirExists(currentDir):
    when defined(windows):
      discard execCmdEx("cmd /c rmdir " & q(currentDir))
    else:
      removeDir(currentDir)
  when defined(windows):
    discard execCmdEx("cmd /c mklink /J " & q(currentDir) & " " & q(versionDir))
  else:
    createSymlink(versionDir, currentDir)

  let manifestPath = sandbox.bucketManifestDir / (app & ".json")
  writeMinimalManifest(manifestPath, version, executableName, executablePath)

  result = ScoopFixtureApp(
    name: app,
    version: version,
    executableName: executableName,
    versionDir: versionDir,
    currentDir: currentDir,
    executablePath: executablePath,
    manifestPath: manifestPath)

proc fixtureExecutablePayload*(versionMarker: string): string =
  ## A trivial Windows batch script that prints the version marker when
  ## invoked with `--version` and otherwise echoes its args. This is
  ## byte-stable per `versionMarker`, so the execution-profile checksum
  ## is reproducible across CI runs.
  "@echo off\r\n" &
  "if /I \"%1\"==\"--version\" (\r\n" &
  "  echo " & versionMarker & "\r\n" &
  "  exit /b 0\r\n" &
  ")\r\n" &
  "echo " & versionMarker & " args=%*\r\n" &
  "exit /b 0\r\n"

proc fixtureBuildActionPayload*(versionMarker: string): string =
  ## A Windows batch fixture suitable for being driven by `repro build`:
  ## takes `--source <path>` and `--output <path>`, writes the marker
  ## plus the source-file contents to the output file. Byte-stable
  ## per `versionMarker` so the execution-profile checksum is
  ## reproducible.
  "@echo off\r\n" &
  "setlocal enabledelayedexpansion\r\n" &
  "if /I \"%1\"==\"--version\" (\r\n" &
  "  echo " & versionMarker & "\r\n" &
  "  exit /b 0\r\n" &
  ")\r\n" &
  "set SRC=\r\n" &
  "set OUT=\r\n" &
  ":parseLoop\r\n" &
  "if \"%~1\"==\"\" goto :done\r\n" &
  "if /I \"%~1\"==\"--source\" ( set SRC=%~2 & shift & shift & goto :parseLoop )\r\n" &
  "if /I \"%~1\"==\"--output\" ( set OUT=%~2 & shift & shift & goto :parseLoop )\r\n" &
  "shift\r\n" &
  "goto :parseLoop\r\n" &
  ":done\r\n" &
  "if not defined SRC exit /b 64\r\n" &
  "if not defined OUT exit /b 65\r\n" &
  "for %%I in (\"!OUT!\") do set OUTDIR=%%~dpI\r\n" &
  "if not exist \"!OUTDIR!\" mkdir \"!OUTDIR!\"\r\n" &
  "set /p SRCCONTENT=<\"!SRC!\"\r\n" &
  "(echo " & versionMarker & ":!SRCCONTENT!)>\"!OUT!\"\r\n" &
  "exit /b 0\r\n"

proc fixtureUseDef*(packageSelector, executableName, bucket, app, version,
                   preferredVersion, manifestChecksum, executablePath: string;
                   requiresExecutionProfileChecksum = true):
    InterfaceToolUse =
  ## Construct the InterfaceToolUse the adapter would receive from
  ## interface extraction. Tests use this to drive resolveScoopTool
  ## directly without compiling a fixture provider binary on each run.
  result = InterfaceToolUse(
    rawConstraint: packageSelector,
    packageSelector: packageSelector,
    executableName: executableName,
    location: SourceLocation(file: "fixture", line: 1))
  result.scoopProvisioning = @[InterfaceScoopProvisioning(
    packageName: packageSelector,
    bucket: bucket,
    app: app,
    version: version,
    preferredVersion: preferredVersion,
    manifestChecksum: manifestChecksum,
    executablePath: executablePath,
    requiresExecutionProfileChecksum: requiresExecutionProfileChecksum,
    packageId: bucket & "/" & app,
    lockIdentity: "scoop:" & bucket & "/" & app,
    location: SourceLocation(file: "fixture", line: 2))]

# ---------------------------------------------------------------------------
# Installable-bucket fixtures: helpers that produce a manifest pointing at a
# `file://` URL with a real archive on disk, so that real `scoop install`
# shell-out is exercised end-to-end (Issue 2 of the M55 review).
# ---------------------------------------------------------------------------

type
  InstallableScoopApp* = object
    name*: string
    version*: string
    executableName*: string
    archivePath*: string        # zip file on disk that the manifest points at
    archiveSha256*: string      # sha256 hex of the zip bytes
    manifestPath*: string       # <bucketManifestDir>/<app>.json
    manifestChecksum*: string   # blake3 of the manifest JSON bytes
    versionDir*: string         # <root>/apps/<app>/<version> — NOT created
    currentDir*: string         # <root>/apps/<app>/current — NOT created
    expectedInstalledExecutable*: string

proc sha256HexOfFile*(path: string): string =
  ## Compute the SHA-256 of a file's bytes as lowercase hex, using the
  ## host's standard hashing utility. Real Scoop validates the archive's
  ## sha256 against the manifest's `hash` field before extracting, so the
  ## test fixture has to match what the host will see byte-for-byte.
  when defined(windows):
    # `certutil -hashfile <path> SHA256` is a Windows built-in that has
    # been present since Windows 7 / Server 2008 R2. Output is a header
    # line, the hex digest (sometimes space-separated), and a trailer.
    # Prefer it over PowerShell so the test does not depend on the host
    # shipping a recent enough PowerShell with Get-FileHash.
    let res = execCmdEx("certutil -hashfile " & quoteShell(path) & " SHA256")
    if res.exitCode != 0:
      raise newException(OSError,
        "sha256HexOfFile: certutil exited " & $res.exitCode &
        "\n" & res.output)
    for line in res.output.splitLines:
      let stripped = line.strip()
      if stripped.len == 0:
        continue
      if stripped.toLowerAscii().startsWith("sha256") or
         stripped.startsWith("CertUtil:"):
        continue
      let candidate = stripped.replace(" ", "").toLowerAscii()
      if candidate.len == 64 and candidate.allCharsInSet(HexDigits):
        return candidate
    raise newException(OSError,
      "sha256HexOfFile: could not parse certutil output\n" & res.output)
  else:
    let candidate = findExe("sha256sum")
    let command =
      if candidate.len > 0:
        candidate & " " & quoteShell(path)
      else:
        let shasum = findExe("shasum")
        if shasum.len == 0:
          raise newException(OSError,
            "sha256HexOfFile: neither sha256sum nor shasum found on PATH")
        shasum & " -a 256 " & quoteShell(path)
    let res = execCmdEx(command)
    if res.exitCode != 0:
      raise newException(OSError,
        "sha256HexOfFile: hasher exited " & $res.exitCode & "\n" & res.output)
    res.output.splitWhitespace()[0].toLowerAscii()

proc writeInstallableManifest*(manifestPath, version, executableName,
                              fileUrl, sha256Hex: string): string =
  ## Write a manifest the real Scoop installer can act on: it points at a
  ## `file://` URL of a real zip archive on disk, declares the sha256 of
  ## that archive, and names the executable for shimming. Returns the
  ## BLAKE3 hex of the manifest JSON bytes — the package author copies
  ## this into the package's `manifestChecksum`.
  let manifest = %*{
    "version": version,
    "description": "Reprobuild M55 install-path fixture",
    "homepage": "https://github.com/metacraft-labs/reprobuild",
    "license": "MIT",
    "url": fileUrl,
    "hash": sha256Hex,
    "bin": executableName
  }
  createDir(manifestPath.parentDir)
  writeFile(manifestPath, manifest.pretty())
  blake3HexFile(manifestPath)

proc setupInstallableScoopApp*(sandbox: ScoopSandbox; tempRoot, app, version,
                              executableName, executablePayload: string):
    InstallableScoopApp =
  ## Stages an installable Scoop app: writes a zip containing the fixture
  ## executable, computes its sha256, writes the bucket manifest with a
  ## `file://` URL pointing at the zip and the matching `hash` field, and
  ## reports the BLAKE3 manifest checksum. CRITICALLY: it does NOT create
  ## `apps/<app>/<version>/` — that directory must be populated by real
  ## Scoop's `install` shell-out so the adapter exercises the install
  ## code path (see Issue 2 of the M55 gate review).
  let stagingDir = tempRoot / "install-fixture-payload" / app
  let executableStagingPath = stagingDir / executableName
  createDir(stagingDir)
  writeFile(executableStagingPath, executablePayload)

  let archivePath = tempRoot / "install-fixture" /
    (app & "-" & version & ".zip")
  createDir(archivePath.parentDir)
  if fileExists(archivePath):
    removeFile(archivePath)

  when defined(windows):
    # Compress-Archive packs the staging dir's contents at the zip root,
    # so the extracted layout under apps/<app>/<version>/ is just the
    # executable file at top level. That matches the manifest's `bin`
    # field referring to the file by its leaf name.
    let psCommand = "Compress-Archive -Path " &
      quoteShell(stagingDir & "\\*") & " -DestinationPath " &
      quoteShell(archivePath) & " -Force"
    let zipRes = execCmdEx("powershell -NoProfile -ExecutionPolicy Bypass " &
      "-Command " & quoteShell(psCommand))
    if zipRes.exitCode != 0:
      raise newException(OSError,
        "setupInstallableScoopApp: Compress-Archive exited " &
        $zipRes.exitCode & "\n" & zipRes.output)
  else:
    let zip = findExe("zip")
    if zip.len == 0:
      raise newException(OSError,
        "setupInstallableScoopApp: zip binary not found on PATH")
    let zipRes = execCmdEx(zip & " -j " & quoteShell(archivePath) & " " &
      quoteShell(executableStagingPath))
    if zipRes.exitCode != 0:
      raise newException(OSError,
        "setupInstallableScoopApp: zip exited " & $zipRes.exitCode & "\n" &
        zipRes.output)

  let sha256Hex = sha256HexOfFile(archivePath)
  let fileUrl = "file:///" & archivePath.replace('\\', '/')

  let manifestPath = sandbox.bucketManifestDir / (app & ".json")
  let manifestChecksum = writeInstallableManifest(manifestPath, version,
    executableName, fileUrl, sha256Hex)

  let versionDir = sandbox.appsDir / app / version
  let currentDir = sandbox.appsDir / app / "current"

  # Defensive: the whole point of this fixture is that
  # apps/<app>/<version>/ is created by Scoop's own install pipeline.
  # Wipe any residue from a previous run.
  let appRoot = sandbox.appsDir / app
  if dirExists(appRoot):
    deleteJunctionsRec(appRoot)
    removeDir(appRoot)

  result = InstallableScoopApp(
    name: app,
    version: version,
    executableName: executableName,
    archivePath: archivePath,
    archiveSha256: sha256Hex,
    manifestPath: manifestPath,
    manifestChecksum: manifestChecksum,
    versionDir: versionDir,
    currentDir: currentDir,
    expectedInstalledExecutable: versionDir / executableName)
