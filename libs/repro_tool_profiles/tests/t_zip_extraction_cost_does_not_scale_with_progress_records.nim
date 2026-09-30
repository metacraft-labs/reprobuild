## Tool-store zip extraction through PowerShell: correctness, and a per-entry
## cost budget.
##
## Test-double policy: this test uses no mocks or test doubles. Every case
## runs a real PowerShell against real zip archives on the real filesystem.
## Every case runs the tool store's own command line (`zipExtractCommand`).
## On Windows the PowerShell is the one `resolveZipExtractor` chooses
## (`powershell.exe`, Windows PowerShell 5.1), and the first case also goes
## through the production entry point, `extractTarballArchive`. Elsewhere the
## product picks `unzip`, so the cases use `pwsh`. If no PowerShell is
## present, the cases skip and give that as the reason.
##
## What this reproduces: the tool store extracted zip archives with the
## `Expand-Archive` cmdlet. Under Windows PowerShell 5.1 that cmdlet writes a
## progress record per entry, and when output is captured those records are
## serialized onto the pipe. The cost measured on a 4-vCPU CI VM was about
## 90 ms per entry:
##   * a 2,000-entry synthetic zip took 177 s through the old command and
##     15.8 s through `ZipFile.ExtractToDirectory`;
##   * the 12,154-entry MinGW toolchain zip took about 40 minutes, against
##     199 s.
## A single `repro exec` that provisioned the MinGW, Go and PostgreSQL zips
## sat silent for over two hours and looked hung.
##
## The cost is not specific to Windows PowerShell. With the old command put
## back, the budget case below takes 255.6 s under PowerShell 7.5 on Linux,
## against 3.9 s with `ZipFile.ExtractToDirectory`. So the case catches a
## regression on any host that has a PowerShell. The budget is 3,000 entries
## in 60 s.

import std/[os, osproc, strutils, times, unittest]

import repro_tool_profiles {.all.}

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
    let extractor = resolveZipExtractor()
    doAssert extractor.kind == "powershell",
      "on Windows the tool store must choose PowerShell, got " & extractor.kind
    extractor.exe
  else:
    findExe("pwsh")

proc makeFixture(ps, path: string; entries: int) =
  ## Builds the fixture with .NET's own zip writer. The archive is
  ## deliberately named `.archive`, as tool-store downloads are, because the
  ## old command could only read a file named `.zip`.
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

proc extractZip(ps, archive, destination: string): string =
  ## Runs the tool store's zip command line with `ps` and returns the
  ## captured output. On Windows `ps` is the extractor that
  ## `resolveZipExtractor` chose. Raises if extraction fails.
  createDir(destination)
  let res = execCmdEx(zipExtractCommand((exe: ps, kind: "powershell"),
    archive, destination))
  if res.exitCode != 0:
    raise newException(OSError,
      "zip extraction failed (exit " & $res.exitCode & "):\n" & res.output)
  res.output

proc countFiles(dir: string): int =
  for _ in walkDirRec(dir):
    inc result

suite "tool-store zip extraction through PowerShell":
  let ps = findPowerShell()
  # The paths carry a space and an apostrophe. Both must survive the
  # command line and the single-quoted PowerShell literals the script uses.
  let root = getTempDir() / ("repro zip o'test " & $getCurrentProcessId())
  removeDir(root)
  createDir(root)

  test "an extension-less archive extracts completely, quotes and all":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "small.archive"
      makeFixture(ps, archive, 10)
      let dest = root / "small dest"
      discard extractZip(ps, archive, dest)
      check readFile(dest / "pkg" / "bin" / "tool.exe") == "tool-bytes"
      check readFile(dest / "pkg" / "share" / "it's here.txt") == "quoted"
      check readFile(dest / "pkg" / "many" / "d9" / "f9.txt") == "x9"
      when defined(windows):
        check readFile(dest / "pkg" / "win" / "sep.txt") == "backslash"
        # And through the production entry point, which resolves the
        # extractor itself and raises on a non-zero exit.
        let viaStore = root / "small via store"
        extractTarballArchive(archive, viaStore, "zip", 0)
        check readFile(viaStore / "pkg" / "share" / "it's here.txt") == "quoted"

  test "a corrupt archive fails loudly instead of extracting nothing":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      let archive = root / "corrupt.archive"
      writeFile(archive, "PK\x03\x04 this is not a zip archive")
      expect OSError:
        discard extractZip(ps, archive, root / "corrupt dest")

  test "3,000 entries extract within 60 s and emit no progress records":
    if ps.len == 0:
      skip("no PowerShell on this host; install pwsh to run this case")
    else:
      const entries = 3000
      let archive = root / "many.archive"
      makeFixture(ps, archive, entries)
      let dest = root / "many dest"
      let started = epochTime()
      let output = extractZip(ps, archive, dest)
      let elapsed = epochTime() - started
      echo "extracted ", entries, " entries in ", elapsed.formatFloat(ffDecimal, 1), " s"
      check countFiles(dest / "pkg" / "many") == entries
      # Windows PowerShell serializes progress onto a redirected stream as
      # CLIXML `S="progress"` objects. One per entry is the cost this case
      # guards against.
      check "S=\"progress\"" notin output
      check elapsed < 60.0

  removeDir(root)
