## Builtin-adapter zip extraction through PowerShell: correctness, and a
## per-entry cost budget.
##
## Test-double policy: this test uses no mocks or test doubles. Every case
## runs a real PowerShell against real zip archives on the real filesystem,
## through the adapter's own command line (`powershellZipExtractCommand`).
## On Windows the PowerShell is `powershell.exe` (Windows PowerShell 5.1),
## the one `extractZip` chooses, and the first case also goes through
## `extractZip` itself. Elsewhere the adapter prefers `unzip`, so the cases
## use `pwsh`. If no PowerShell is present, the cases skip and give that as
## the reason.
##
## What this reproduces: the builtin adapter extracted zip packages with the
## `Expand-Archive` cmdlet, which writes a progress record per entry. With
## output captured, those records cost about 90 ms per entry on a 4-vCPU
## Windows CI machine, so a 12,000-entry archive took about 40 minutes. The
## tool store had the same defect and the same fix; see
## `libs/repro_tool_profiles/tests/t_zip_extraction_cost_does_not_scale_with_progress_records.nim`.
## The cost is not specific to Windows PowerShell: the old command took
## 255 s for the budget case below under PowerShell 7.5 on Linux, so the
## case catches a regression on any host that has a PowerShell. The budget
## is 3,000 entries in 60 s.

import std/[os, osproc, strutils, times, unittest]

import repro_home_apply/builtin_adapter {.all.}

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
if ($env:REPRO_ZIP_FIXTURE_BACKSLASH -eq '1') { Add-Entry 'pkg\win\sep.txt' 'backslash' }
for ($i = 0; $i -lt $count; $i++) { Add-Entry ("pkg/many/d{0}/f{1}.txt" -f ($i % 50), $i) ("x{0}" -f $i) }
$zip.Dispose()
$fs.Dispose()
"""

proc findPowerShell(): string =
  when defined(windows):
    findExe("powershell")
  else:
    findExe("pwsh")

proc makeFixture(ps, path: string; entries: int) =
  ## Builds the fixture with .NET's own zip writer. The archive is named
  ## `.archive`, not `.zip`, because `Expand-Archive` could only read a file
  ## named `.zip` and the replacement must not care.
  putEnv("REPRO_ZIP_FIXTURE_PATH", path)
  putEnv("REPRO_ZIP_FIXTURE_ENTRIES", $entries)
  putEnv("REPRO_ZIP_FIXTURE_BACKSLASH",
    (when defined(windows): "1" else: "0"))
  let scriptPath = path & ".make.ps1"
  writeFile(scriptPath, FixtureScript)
  let res = execCmdEx(quoteShell(ps) &
    " -NoProfile -NonInteractive -ExecutionPolicy Bypass -File " &
    quoteShell(scriptPath))
  doAssert res.exitCode == 0, "fixture creation failed:\n" & res.output
  doAssert fileExists(path)

proc extractZipWith(ps, archive, destination: string): string =
  ## Runs the adapter's PowerShell zip command line and returns the captured
  ## output. Raises if extraction fails.
  createDir(destination)
  let res = execCmdEx(powershellZipExtractCommand(ps, archive, destination))
  if res.exitCode != 0:
    raise newException(OSError,
      "zip extraction failed (exit " & $res.exitCode & "):\n" & res.output)
  res.output

proc countFiles(dir: string): int =
  for _ in walkDirRec(dir):
    inc result

suite "builtin-adapter zip extraction through PowerShell":
  let ps = findPowerShell()
  # The paths carry a space and an apostrophe. Both must survive the
  # command line and the single-quoted PowerShell literals.
  let root = getTempDir() / ("repro builtin zip o'test " & $getCurrentProcessId())
  removeDir(root)
  createDir(root)

  test "an extension-less archive extracts completely, quotes and all":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "small.archive"
      makeFixture(ps, archive, 10)
      let dest = root / "small dest"
      discard extractZipWith(ps, archive, dest)
      check readFile(dest / "pkg" / "bin" / "tool.exe") == "tool-bytes"
      check readFile(dest / "pkg" / "share" / "it's here.txt") == "quoted"
      check readFile(dest / "pkg" / "many" / "d9" / "f9.txt") == "x9"
      when defined(windows):
        check readFile(dest / "pkg" / "win" / "sep.txt") == "backslash"
        # And through the adapter's own entry point, which picks
        # PowerShell on Windows and raises on a non-zero exit.
        let viaAdapter = root / "small via adapter"
        extractZip("fixture", archive, viaAdapter)
        check readFile(viaAdapter / "pkg" / "share" / "it's here.txt") ==
          "quoted"

  test "a corrupt archive fails loudly instead of extracting nothing":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "corrupt.archive"
      writeFile(archive, "PK\x03\x04 this is not a zip archive")
      expect OSError:
        discard extractZipWith(ps, archive, root / "corrupt dest")
      when defined(windows):
        expect EBuiltinExtractFailed:
          extractZip("fixture", archive, root / "corrupt via adapter")

  test "3,000 entries extract within 60 s and emit no progress records":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      const entries = 3000
      let archive = root / "many.archive"
      makeFixture(ps, archive, entries)
      let dest = root / "many dest"
      let started = epochTime()
      let output = extractZipWith(ps, archive, dest)
      let elapsed = epochTime() - started
      echo "extracted ", entries, " entries in ",
        elapsed.formatFloat(ffDecimal, 1), " s"
      check countFiles(dest / "pkg" / "many") == entries
      # Windows PowerShell serializes progress onto a redirected stream as
      # CLIXML `S="progress"` objects. One per entry is the cost this case
      # guards against.
      check "S=\"progress\"" notin output
      check elapsed < 60.0

  removeDir(root)
