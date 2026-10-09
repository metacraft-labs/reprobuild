## `expandArchive` on Windows, run for real: correctness, the overwrite
## contract, and a per-entry cost budget.
##
## Test-double policy: this test uses no mocks or test doubles. Every case
## runs the exact argv `buildZipArgvWindows` lowers, in a real PowerShell
## process, against real zip archives on the real filesystem. On Windows
## that is `powershell.exe` (Windows PowerShell 5.1), the program the argv
## names. Elsewhere the argv's first element is replaced by `pwsh` and
## nothing else changes. If no PowerShell is present, the cases skip and
## give that as the reason.
##
## What this reproduces: the Windows branch of `expandArchive` copied the
## archive to a scratch `.zip` under `$env:TEMP` and ran the `Expand-Archive`
## cmdlet on it. That cmdlet writes a progress record per entry, and with
## output captured those records cost about 90 ms per entry on a 4-vCPU
## Windows CI machine, so a 12,000-entry archive took about 40 minutes. The
## tool store had the same defect; see
## `libs/repro_tool_profiles/tests/t_zip_extraction_cost_does_not_scale_with_progress_records.nim`,
## which measured the old command at 255 s for the budget used below under
## PowerShell 7.5 on Linux. So the budget case catches a regression on any
## host that has a PowerShell. The budget is 3,000 entries in 60 s.
##
## Unlike the tool store, this action extracts into a destination that may
## already hold files, and its contract is `Expand-Archive -Force`'s:
## overwrite what the archive carries, leave everything else. It therefore
## walks the entries itself, and so must refuse an entry that escapes the
## destination itself. Both are pinned here.

import std/[os, osproc, streams, strtabs, strutils, times, unittest]

import repro_dsl_stdlib/packages/expand_archive

const FixtureScript = """
$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$path = $env:REPRO_ZIP_FIXTURE_PATH
$count = [int]$env:REPRO_ZIP_FIXTURE_ENTRIES
$fs = [System.IO.File]::Open($path, 'CreateNew')
$zip = New-Object System.IO.Compression.ZipArchive($fs, 'Create')
function Add-Entry([string]$name, [string]$text) {
  $w = New-Object System.IO.StreamWriter($zip.CreateEntry($name).Open())
  $w.Write($text)
  $w.Dispose()
}
Add-Entry 'pkg/bin/tool.exe' 'tool-bytes'
Add-Entry "pkg/share/it's here.txt" 'quoted'
[void]$zip.CreateEntry('pkg/empty-dir/')
if ($env:REPRO_ZIP_FIXTURE_BACKSLASH -eq '1') { Add-Entry 'pkg\win\sep.txt' 'backslash' }
if ($env:REPRO_ZIP_FIXTURE_ESCAPE -eq '1') { Add-Entry '../escaped.txt' 'escaped' }
for ($i = 0; $i -lt $count; $i++) { Add-Entry ("pkg/many/d{0}/f{1}.txt" -f ($i % 50), $i) ("x{0}" -f $i) }
$zip.Dispose()
$fs.Dispose()
"""

type RunResult = object
  exitCode: int
  output: string

proc findPowerShell(): string =
  when defined(windows):
    findExe("powershell")
  else:
    findExe("pwsh")

proc runArgv(argv: seq[string]; tempDir = ""): RunResult =
  ## Runs `argv` with no shell in between, as the engine spawns an
  ## `inlineExecCall`. With `tempDir` set, the child's temporary directory
  ## is pointed there so a scratch file would be observable.
  var env = newStringTable(modeCaseInsensitive)
  for key, value in envPairs():
    env[key] = value
  if tempDir.len > 0:
    env["TEMP"] = tempDir
    env["TMP"] = tempDir
    env["TMPDIR"] = tempDir
  let process = startProcess(argv[0], args = argv[1 .. ^1], env = env,
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  let stream = process.outputStream
  while not stream.atEnd():
    result.output.add(stream.readAll())
  result.exitCode = process.waitForExit()

proc makeFixture(ps, path: string; entries: int; escape = false) =
  ## Builds the fixture with .NET's own zip writer. The archive is named
  ## `.archive`, not `.zip`: `Expand-Archive` could only read a file named
  ## `.zip`, and the replacement must not care.
  putEnv("REPRO_ZIP_FIXTURE_PATH", path)
  putEnv("REPRO_ZIP_FIXTURE_ENTRIES", $entries)
  putEnv("REPRO_ZIP_FIXTURE_BACKSLASH",
    (when defined(windows): "1" else: "0"))
  putEnv("REPRO_ZIP_FIXTURE_ESCAPE", (if escape: "1" else: "0"))
  let scriptPath = path & ".make.ps1"
  writeFile(scriptPath, FixtureScript)
  let res = runArgv(@[ps, "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
    "Bypass", "-File", scriptPath])
  doAssert res.exitCode == 0, "fixture creation failed:\n" & res.output
  doAssert fileExists(path)

proc lowered(ps, archive, destination: string): seq[string] =
  ## The argv the wrapper lowers on Windows, with only the program replaced
  ## by the PowerShell this host has.
  result = buildZipArgvWindows(archive, destination)
  doAssert result[0] == "powershell"
  result[0] = ps

proc countFiles(dir: string): int =
  for _ in walkDirRec(dir):
    inc result

proc zipFilesUnder(dir: string): seq[string] =
  for path in walkDirRec(dir):
    if path.toLowerAscii().endsWith(".zip"):
      result.add(path)

suite "expandArchive Windows zip extraction, run for real":
  let ps = findPowerShell()
  # The paths carry a space and an apostrophe. Both must survive the argv
  # and the single-quoted PowerShell literals.
  let root = getTempDir() / ("repro expand o'archive " & $getCurrentProcessId())
  removeDir(root)
  createDir(root)

  test "an extension-less archive extracts completely with no scratch copy":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "small.archive"
      makeFixture(ps, archive, 10)
      let dest = root / "small dest"
      let temp = root / "child temp"
      createDir(temp)
      # The destination does not exist yet; the action creates it.
      let res = runArgv(lowered(ps, archive, dest), temp)
      check res.exitCode == 0
      if res.exitCode != 0:
        echo res.output
      check readFile(dest / "pkg" / "bin" / "tool.exe") == "tool-bytes"
      check readFile(dest / "pkg" / "share" / "it's here.txt") == "quoted"
      check readFile(dest / "pkg" / "many" / "d9" / "f9.txt") == "x9"
      check dirExists(dest / "pkg" / "empty-dir")
      when defined(windows):
        check readFile(dest / "pkg" / "win" / "sep.txt") == "backslash"
      # The old command copied every archive to a scratch .zip here.
      check zipFilesUnder(temp).len == 0

  test "an existing destination is overwritten in place, like -Force":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "overwrite.archive"
      makeFixture(ps, archive, 5)
      let dest = root / "overwrite dest"
      createDir(dest / "pkg" / "bin")
      writeFile(dest / "pkg" / "bin" / "tool.exe", "an older tool")
      writeFile(dest / "keep.txt", "not in the archive")
      let res = runArgv(lowered(ps, archive, dest))
      check res.exitCode == 0
      if res.exitCode != 0:
        echo res.output
      check readFile(dest / "pkg" / "bin" / "tool.exe") == "tool-bytes"
      check readFile(dest / "keep.txt") == "not in the archive"
      # And again over its own output, as a re-run after a lost marker is.
      check runArgv(lowered(ps, archive, dest)).exitCode == 0
      check readFile(dest / "pkg" / "many" / "d4" / "f4.txt") == "x4"

  test "an entry that escapes the destination fails the action":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "escape.archive"
      makeFixture(ps, archive, 0, escape = true)
      let parent = root / "escape parent"
      let dest = parent / "dest"
      let res = runArgv(lowered(ps, archive, dest))
      check res.exitCode != 0
      check "escapes the destination" in res.output
      check not fileExists(parent / "escaped.txt")

  test "a missing or corrupt archive fails loudly":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      check runArgv(lowered(ps, root / "missing.archive",
        root / "missing dest")).exitCode != 0
      let corrupt = root / "corrupt.archive"
      writeFile(corrupt, "PK\x03\x04 this is not a zip archive")
      check runArgv(lowered(ps, corrupt, root / "corrupt dest")).exitCode != 0

  test "3,000 entries extract within 60 s and emit no progress records":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      const entries = 3000
      let archive = root / "many.archive"
      makeFixture(ps, archive, entries)
      let dest = root / "many dest"
      let started = epochTime()
      let res = runArgv(lowered(ps, archive, dest))
      let elapsed = epochTime() - started
      echo "extracted ", entries, " entries in ",
        elapsed.formatFloat(ffDecimal, 1), " s"
      check res.exitCode == 0
      check countFiles(dest / "pkg" / "many") == entries
      # Windows PowerShell serializes progress onto a redirected stream as
      # CLIXML `S="progress"` objects. One per entry is the cost this case
      # guards against.
      check "S=\"progress\"" notin res.output
      check elapsed < 60.0

  removeDir(root)
