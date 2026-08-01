## Windows-System-Resources Phase F — ``expandArchive`` stdlib package.
##
## The package wraps platform-native archive extraction utilities
## behind a single typed ``build:`` surface. The pure helpers
## (``parseExpandArchiveFormat``, ``detectExpandArchiveFormat``,
## ``resolveExpandArchiveArgv``, ``buildTarArgv``, ...) carry the load-
## bearing argv shape; the ``build*`` proc itself binds them to the
## host's compile-time platform and lowers to a ``BuildActionDef``
## via ``inlineExecCall``.
##
## What this test pins:
##
##   * Format parser accepts every spec-listed tag verbatim + rejects
##     garbage.
##   * Filename auto-detect resolves every spec-listed extension.
##   * The pure ``resolveExpandArchiveArgv`` dispatch produces the
##     spec-mandated argv for ``zip`` on BOTH platform branches and
##     for every tar-family format.
##   * ``stripComponents`` lands as ``--strip-components=N`` for tar
##     and is rejected for zip with a clear error.
##   * Failure modes: empty arg / marker outside destination /
##     unknown format / negative stripComponents.
##   * The ``build*`` proc returns a ``BuildActionDef`` whose
##     ``requiresElevation``, ``outputs``, ``inputs``, ``deps``,
##     ``call``, and ``commandStatsId`` carry the expected values; and
##     the host-platform branch of the argv dispatch is exercised
##     directly via the live ``build*`` proc.
##
## Test-double policy: this file uses no mocks or test doubles. The
## cross-process determinism gate below launches two real copies of this
## test executable so process identity and ambient temporary-directory
## differences cross an actual OS process boundary.

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

import repro_project_dsl

import repro_dsl_stdlib/packages/expand_archive
# Re-importing the package module under a short alias is the same
# pattern recipes use; we keep the explicit import so the symbol
# resolution is direct.
import repro_dsl_stdlib/packages/expand_archive as expandArchive

const EmitWindowsZipArgvFlag = "--emit-windows-zip-argv"

if paramCount() == 1 and paramStr(1) == EmitWindowsZipArgvFlag:
  # Purpose-built subprocess mode for the cross-process determinism gate.
  # Keep the process alive briefly so two emitters overlap and therefore
  # cannot share a process id.
  sleep(250)
  var payload = newJObject()
  payload["pid"] = %getCurrentProcessId()
  payload["argv"] = %buildZipArgvWindows(
    "C:\\stable-input\\runner.zip", "C:\\stable-output")
  stdout.write($payload)
  quit(0)

proc emitterEnvironment(tempRoot: string): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["TEMP"] = tempRoot
  result["TMP"] = tempRoot
  result["TMPDIR"] = tempRoot

proc startArgvEmitter(tempRoot: string): Process =
  startProcess(
    getAppFilename(),
    args = @[EmitWindowsZipArgvFlag],
    env = emitterEnvironment(tempRoot),
    options = {poStdErrToStdOut})

proc finishArgvEmitter(process: Process): JsonNode =
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    raise newException(IOError,
      "Windows zip argv emitter exited " & $exitCode & ": " & output)
  parseJson(output)

suite "Phase F — expandArchive format dispatch (pure helpers)":

  test "parseExpandArchiveFormat accepts every spec-listed tag":
    check parseExpandArchiveFormat("") == eafUnknown
    check parseExpandArchiveFormat("auto") == eafUnknown
    check parseExpandArchiveFormat("zip") == eafZip
    check parseExpandArchiveFormat("ZIP") == eafZip
    check parseExpandArchiveFormat("tar") == eafTar
    check parseExpandArchiveFormat("tar.gz") == eafTarGz
    check parseExpandArchiveFormat("tgz") == eafTarGz
    check parseExpandArchiveFormat("tar.bz2") == eafTarBz2
    check parseExpandArchiveFormat("tbz2") == eafTarBz2
    check parseExpandArchiveFormat("tar.xz") == eafTarXz
    check parseExpandArchiveFormat("txz") == eafTarXz
    check parseExpandArchiveFormat("7z") == eafSevenZip
    check parseExpandArchiveFormat("sevenzip") == eafSevenZip

  test "parseExpandArchiveFormat rejects unknown tags":
    expect ValueError:
      discard parseExpandArchiveFormat("rar")
    expect ValueError:
      discard parseExpandArchiveFormat("xz")  # naked compression, not archive

  test "detectExpandArchiveFormat resolves every spec-listed extension":
    check detectExpandArchiveFormat("x.zip") == eafZip
    check detectExpandArchiveFormat("x.tar") == eafTar
    check detectExpandArchiveFormat("x.tar.gz") == eafTarGz
    check detectExpandArchiveFormat("x.tgz") == eafTarGz
    check detectExpandArchiveFormat("x.tar.bz2") == eafTarBz2
    check detectExpandArchiveFormat("x.tbz2") == eafTarBz2
    check detectExpandArchiveFormat("x.tar.xz") == eafTarXz
    check detectExpandArchiveFormat("x.txz") == eafTarXz
    check detectExpandArchiveFormat("x.7z") == eafSevenZip
    # Mixed case in the path stays recognised.
    check detectExpandArchiveFormat(
      "C:\\Foo\\Actions-Runner-Win-X64.ZIP") == eafZip
    # Double-extension precedence: ``.tar.gz`` wins over ``.gz``.
    check detectExpandArchiveFormat(
      "/var/cache/foo-1.2.3.tar.gz") == eafTarGz

  test "detectExpandArchiveFormat rejects unrecognised extensions":
    expect ValueError:
      discard detectExpandArchiveFormat("/var/cache/foo.rar")
    expect ValueError:
      # No extension at all.
      discard detectExpandArchiveFormat("/var/cache/runner")

  test "resolveExpandArchiveFormat: explicit format overrides auto-detect":
    # The archive name says zip but the explicit format says tar.gz.
    # The override wins.
    check resolveExpandArchiveFormat("x.zip", "tar.gz") == eafTarGz
    check resolveExpandArchiveFormat("x.tar.gz", "") == eafTarGz
    check resolveExpandArchiveFormat("x.tar.gz", "auto") == eafTarGz

suite "Phase F — argv assemblers (pure)":

  test "Linux/macOS zip: unzip -q -o <archive> -d <dest>":
    let argv = resolveExpandArchiveArgv(
      "/tmp/runner.zip", "/opt/actions-runner", eafZip,
      stripComponents = 0, onWindows = false)
    check argv == @["unzip", "-q", "-o",
      "/tmp/runner.zip", "-d", "/opt/actions-runner"]

  test "Windows zip: exact deterministic PowerShell argv":
    let argv = resolveExpandArchiveArgv(
      "C:\\runner's cache\\runner.zip",
      "C:\\agent's runner", eafZip,
      stripComponents = 0, onWindows = true)
    check argv == @[
      "powershell",
      "-NoProfile",
      "-Command",
      "$ErrorActionPreference = 'Stop'; " &
        "$scratch = Join-Path $env:TEMP " &
          "('repro-expand-archive-' + $PID + '.zip'); " &
        "try { " &
          "Copy-Item -LiteralPath " &
            "'C:\\runner''s cache\\runner.zip' " &
            "-Destination $scratch -Force; " &
          "Expand-Archive -LiteralPath $scratch " &
            "-DestinationPath 'C:\\agent''s runner' -Force " &
        "} finally { " &
          "if (Test-Path -LiteralPath $scratch) { " &
            "Remove-Item -LiteralPath $scratch -Force " &
              "-ErrorAction Stop " &
          "} " &
        "}"]

  test "Windows zip lowering is byte-identical across real processes":
    let tempA = getTempDir() / "expand-archive-emitter-a"
    let tempB = getTempDir() / "expand-archive-emitter-b"
    createDir(tempA)
    createDir(tempB)
    let emitterA = startArgvEmitter(tempA)
    let emitterB = startArgvEmitter(tempB)
    let payloadA = finishArgvEmitter(emitterA)
    let payloadB = finishArgvEmitter(emitterB)

    check payloadA["pid"].getInt() != payloadB["pid"].getInt()
    # Compare the complete serialized argv node, not selected substrings.
    check $payloadA["argv"] == $payloadB["argv"]
    check payloadA["argv"].getElems().len == 4
    let command = payloadA["argv"][3].getStr()
    check "$PID" in command
    check $payloadA["pid"].getInt() notin command
    check $payloadB["pid"].getInt() notin command
    check tempA notin command
    check tempB notin command

  test "Windows zip lowering source has no compile-time entropy lookup":
    let sourcePath = currentSourcePath().parentDir / ".." / "src" /
      "repro_dsl_stdlib" / "packages" / "expand_archive.nim"
    let source = readFile(sourcePath)
    for forbidden in [
      "getCurrentProcessId", "epochTime", "cpuTime", "randomize",
      "rand(", "genOid", "getTempDir", "getEnv(\"TEMP\"",
      "getEnv(\"TMP\"", "getEnv(\"TMPDIR\""]:
      check forbidden notin source

  test "tar plain: tar -x -f <archive> -C <dest>":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar", "/opt/x", eafTar,
      stripComponents = 0, onWindows = false)
    check argv == @["tar", "-x", "-f", "/tmp/x.tar", "-C", "/opt/x"]

  test "tar.gz: tar -z -x -f <archive> -C <dest>":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar.gz", "/opt/x", eafTarGz,
      stripComponents = 0, onWindows = false)
    check argv == @["tar", "-z", "-x", "-f",
      "/tmp/x.tar.gz", "-C", "/opt/x"]

  test "tar.bz2: tar -j -x -f <archive> -C <dest>":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar.bz2", "/opt/x", eafTarBz2,
      stripComponents = 0, onWindows = false)
    check argv == @["tar", "-j", "-x", "-f",
      "/tmp/x.tar.bz2", "-C", "/opt/x"]

  test "tar.xz: tar -J -x -f <archive> -C <dest>":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar.xz", "/opt/x", eafTarXz,
      stripComponents = 0, onWindows = false)
    check argv == @["tar", "-J", "-x", "-f",
      "/tmp/x.tar.xz", "-C", "/opt/x"]

  test "tar dispatch is platform-agnostic (Win11 tar.exe ships in System32)":
    # The same argv shape lands regardless of host — tar.exe on
    # Windows accepts the same -x / -f / -C / --strip-components
    # surface as GNU/BSD tar.
    let posixArgv = resolveExpandArchiveArgv(
      "C:\\cache\\x.tar.gz", "C:\\dest", eafTarGz,
      stripComponents = 0, onWindows = false)
    let winArgv = resolveExpandArchiveArgv(
      "C:\\cache\\x.tar.gz", "C:\\dest", eafTarGz,
      stripComponents = 0, onWindows = true)
    check posixArgv == winArgv
    check winArgv[0] == "tar"

  test "stripComponents threaded through tar argv":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar.gz", "/opt/x", eafTarGz,
      stripComponents = 2, onWindows = false)
    check argv == @["tar", "-z", "-x", "-f",
      "/tmp/x.tar.gz", "-C", "/opt/x", "--strip-components=2"]

  test "stripComponents=0 omits the flag (default form)":
    let argv = resolveExpandArchiveArgv(
      "/tmp/x.tar", "/opt/x", eafTar,
      stripComponents = 0, onWindows = false)
    check "--strip-components=0" notin argv

  test "negative stripComponents is rejected":
    expect ValueError:
      discard buildTarArgv("/tmp/x.tar", "/opt/x", eafTar,
        stripComponents = -1)

  test "zip with stripComponents != 0 is rejected with a clear error":
    expect ValueError:
      discard resolveExpandArchiveArgv(
        "/tmp/x.zip", "/opt/x", eafZip,
        stripComponents = 1, onWindows = false)
    expect ValueError:
      discard resolveExpandArchiveArgv(
        "C:\\cache\\x.zip", "C:\\dest", eafZip,
        stripComponents = 1, onWindows = true)

  test "7z is refused politely (not yet implemented)":
    expect ValueError:
      discard resolveExpandArchiveArgv(
        "/tmp/x.7z", "/opt/x", eafSevenZip,
        stripComponents = 0, onWindows = false)

  test "eafUnknown dispatched directly raises (caller must resolve first)":
    expect ValueError:
      discard resolveExpandArchiveArgv(
        "/tmp/x", "/opt/x", eafUnknown,
        stripComponents = 0, onWindows = false)

suite "Phase F — markerInsideDestination":

  test "marker inside destination on POSIX paths":
    check markerInsideDestination(
      "/opt/actions-runner/config.cmd", "/opt/actions-runner") == true

  test "marker inside destination on Windows-style paths":
    check markerInsideDestination(
      "C:\\actions-runner\\config.cmd", "C:\\actions-runner") == true

  test "marker equal to destination is NOT inside":
    # A marker that IS the destination root cannot be a file the
    # archive contains.
    check markerInsideDestination(
      "/opt/actions-runner", "/opt/actions-runner") == false

  test "marker outside destination is rejected":
    check markerInsideDestination(
      "/tmp/other/config.cmd", "/opt/actions-runner") == false

  test "destination prefix is not enough — must be a path-segment boundary":
    # ``/opt/actions-runner-cache/.../`` shares the same prefix as
    # ``/opt/actions-runner`` but is NOT a child of it. The check is
    # path-segment aware (it appends a separator before the prefix
    # comparison).
    check markerInsideDestination(
      "/opt/actions-runner-cache/file", "/opt/actions-runner") == false

  test "empty marker / destination is rejected":
    check markerInsideDestination("", "/opt/x") == false
    check markerInsideDestination("/opt/x/marker", "") == false

suite "Phase F — expandArchive.build typed lowering":

  test "spec example: actions-runner zip with requiresElevation = true":
    # The spec's worked example (§2.2). The host platform decides the
    # argv shape (powershell vs unzip); we pin the load-bearing flags
    # without committing to a specific platform.
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "C:\\actions-runner-cache\\runner.zip",
      destination = "C:\\actions-runner",
      marker = "C:\\actions-runner\\config.cmd",
      requiresElevation = true)
    check act.requiresElevation == true
    check act.outputs == @["C:\\actions-runner\\config.cmd"]
    check "C:\\actions-runner-cache\\runner.zip" in act.inputs
    check act.call.packageName == "reprobuild.builtin"
    check act.call.executableName == "exec"
    check act.commandStatsId == "expandArchive.eafZip"
    # The action id is a stable derivation of (archive, destination).
    check act.id.startsWith("expand-archive-")

  test "build: requiresElevation default false":
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp")
    check act.requiresElevation == false
    check act.outputs == @["/opt/x/.stamp"]
    check "/tmp/x.tar.gz" in act.inputs

  test "build: explicit address overrides the default":
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp",
      address = "extract-thing")
    check act.id == "extract-thing"

  test "build: dependsOn flows into the action's deps":
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp",
      dependsOn = ["fetchUpstream"])
    check act.deps == @["fetchUpstream"]

  test "build: format override threads through to the dispatch":
    # The archive name suggests zip but the explicit format is tar.gz.
    # We don't probe the argv shape (it's host-dependent); instead we
    # pin the commandStatsId which is derived from the resolved
    # format.
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/ambiguous.dat",
      destination = "/opt/x",
      marker = "/opt/x/.stamp",
      format = "tar.gz")
    check act.commandStatsId == "expandArchive.eafTarGz"

  test "build: stripComponents threads to argv (tar-family)":
    # ``stripComponents > 0`` lands as ``--strip-components=N`` in the
    # tar argv. We inspect the action's argv via the call's positional
    # argument values.
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp",
      stripComponents = 3)
    var sawStrip = false
    for arg in act.call.arguments:
      if arg.encodedValue.contains("--strip-components=3"):
        sawStrip = true
    check sawStrip

  test "build: marker outside destination is rejected":
    resetBuildActionRegistry()
    expect ValueError:
      discard expandArchive.build(
        archive = "/tmp/x.tar.gz",
        destination = "/opt/x",
        marker = "/tmp/elsewhere/.stamp")

  test "build: empty archive / destination / marker is rejected":
    resetBuildActionRegistry()
    expect ValueError:
      discard expandArchive.build(archive = "",
        destination = "/opt/x", marker = "/opt/x/.stamp")
    expect ValueError:
      discard expandArchive.build(archive = "/tmp/x.tar.gz",
        destination = "", marker = "/tmp/.stamp")
    expect ValueError:
      discard expandArchive.build(archive = "/tmp/x.tar.gz",
        destination = "/opt/x", marker = "")

  test "build: zip with stripComponents is rejected (no native equivalent)":
    resetBuildActionRegistry()
    expect ValueError:
      discard expandArchive.build(
        archive = "/tmp/x.zip",
        destination = "/opt/x",
        marker = "/opt/x/.stamp",
        stripComponents = 1)

  test "build: unknown format is rejected":
    resetBuildActionRegistry()
    expect ValueError:
      discard expandArchive.build(
        archive = "/tmp/x",
        destination = "/opt/x",
        marker = "/opt/x/.stamp",
        format = "rar")

  test "build: extraInputs flow into the action's inputs":
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp",
      extraInputs = ["/tmp/dep1.bin", "/tmp/dep2.bin"])
    check "/tmp/x.tar.gz" in act.inputs
    check "/tmp/dep1.bin" in act.inputs
    check "/tmp/dep2.bin" in act.inputs

  test "build: host-platform dispatch lands the expected first argv":
    # The compile-time ``when defined(windows)`` branch inside ``build``
    # selects between PowerShell (Windows) and unzip (POSIX) for zip
    # archives. We exercise the host branch here so the dispatch
    # itself stays under test on every CI host.
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.zip",
      destination = "/opt/x",
      marker = "/opt/x/marker")
    when defined(windows):
      # On Windows the first argv element is ``powershell``.
      check act.toolIdentityRefs == @["powershell"]
    else:
      check act.toolIdentityRefs == @["unzip"]

  test "build: tar host-platform dispatch is `tar` on every host":
    resetBuildActionRegistry()
    let act = expandArchive.build(
      archive = "/tmp/x.tar.gz",
      destination = "/opt/x",
      marker = "/opt/x/.stamp")
    # Tar dispatch is identical across platforms: tar.exe on Win11
    # ships in System32 and matches the GNU/BSD tar surface.
    check act.toolIdentityRefs == @["tar"]
