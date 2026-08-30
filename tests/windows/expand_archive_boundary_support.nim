## Host-portable support for the M3f Windows execution-boundary gate.
##
## Everything in this module is PURE: string composition and parsing, no
## filesystem access and no process launch. That is deliberate, and it is the
## point of the file existing at all.
##
## The gate it serves --
## ``tests/windows/windows_expand_archive_execution_boundary.nim`` -- runs only
## on the ``eph-win-x64`` runner class, whose observed queue depth is 45 minutes
## to three hours per job. The two contracts that gate got WRONG are not
## Windows-specific at all:
##
##   1. **How the observer's report is read.** The observer's own exit code is
##      the weakest signal it produces -- an observer that dies before it ever
##      launches the child exits non-zero too. Distinguishing "the child failed"
##      from "the harness failed" needs a value the harness can only print on
##      the path that actually read the child's exit code.
##      (Verification-Harness-Traps.md §2: *a chain of ``success: true`` is not
##      a result*.)
##
##   2. **Which module search path a fixture PowerShell is given.** Windows
##      PowerShell 5.1 (Desktop edition) must not inherit PowerShell 7's
##      ``PSModulePath``: PowerShell 7 ships its own
##      ``$PSHOME\Modules\Microsoft.PowerShell.Security`` whose manifest
##      declares ``CompatiblePSEditions = @("Core")``, so Desktop edition finds
##      that copy first and refuses it -- and ``Get-Acl`` then fails to
##      autoload. (``Microsoft.PowerShell.Archive``, which carries
##      ``Expand-Archive`` / ``Compress-Archive``, has no
##      ``CompatiblePSEditions`` key at all, which is exactly why the archive
##      fixtures kept working while only the ACL arm went red.)
##
## Both are string problems. Factoring them here puts them where they can be
## executed -- and mutation-tested -- on any host, instead of costing a
## multi-hour Windows queue slot per iteration. The cross-platform arm lives in
## ``tests/windows/t_expand_archive_boundary_support.nim``.
##
## Paths are composed with an explicit backslash join rather than ``std/os``'s
## ``/`` operator: these are Windows paths by construction, and the composition
## must produce the same string when this module is compiled on Linux or macOS
## for the cross-platform arm.

import std/strutils

const
  ObserverScratchTag* = "SCRATCH="
    ## Emitted by the observer once the FileSystemWatcher has reported a
    ## created scratch archive.
  ObserverChildExitTag* = "CHILD_EXIT="
    ## Emitted by the observer ONLY after it has read the child's
    ## ``$LASTEXITCODE``. Its absence means the observer never got that far.
  SecurityModuleTag* = "SECURITY_MODULE="
    ## Emitted by the ``Microsoft.PowerShell.Security`` preflight probe.

  WindowsPowerShellFallbackSystemRoot* = "C:\\Windows"
  WindowsPowerShellFallbackProgramFiles* = "C:\\Program Files"

type
  ObserverReport* = object
    ## The parsed form of the observer script's stdout.
    ##
    ## ``scratchReported`` and ``childExitReported`` are separate from their
    ## values on purpose. ``childExit == 0`` and "the observer never reported a
    ## child exit code" are different states, and a harness that cannot tell
    ## them apart reports coverage of a state it never reached.
    scratchReported*: bool
    scratchPath*: string
    childExitReported*: bool
    childExit*: int

proc winJoin*(parts: varargs[string]): string =
  ## Join Windows path segments with a single backslash, on every host.
  ## Empty segments are dropped; a segment that already ends in a backslash
  ## (``C:\``) does not gain a second one.
  for part in parts:
    if part.len == 0:
      continue
    if result.len > 0 and result[^1] != '\\':
      result.add('\\')
    result.add(part)

proc taggedValue*(output, tag: string): tuple[found: bool, value: string] =
  ## Find the value of a ``TAG=value`` marker line in captured process output.
  ##
  ## Marker lines rather than exit codes are how every probe in this harness
  ## reports, because a marker can only be printed by the code path that
  ## produced the thing it names. The scan takes the LAST match so a probe that
  ## legitimately prints twice reports its final answer, and it tolerates the
  ## CRLF and the leading whitespace that PowerShell's own error rendering
  ## interleaves into the same stream.
  for rawLine in output.splitLines():
    let line = rawLine.strip()
    if line.startsWith(tag):
      result.found = true
      result.value = line[tag.len .. ^1]

proc parseObserverReport*(output: string): ObserverReport =
  ## Read the observer's two marker lines out of its captured output.
  ##
  ## A ``CHILD_EXIT=`` line that does not carry a base-10 integer is treated as
  ## NOT REPORTED. The observer prints a non-numeric placeholder when ``&``
  ## failed to launch the child at all, and that state must not be mistaken for
  ## a child that ran.
  let scratch = taggedValue(output, ObserverScratchTag)
  result.scratchReported = scratch.found
  result.scratchPath = scratch.value
  let childExit = taggedValue(output, ObserverChildExitTag)
  if childExit.found:
    try:
      result.childExit = parseInt(childExit.value)
      result.childExitReported = true
    except ValueError:
      # DECLARED MUTATION SURVIVOR (S02): rewriting this line to `discard` is
      # an equivalent mutant -- the field is already false from object
      # zero-initialisation, so the write is documentation. The write is kept
      # because the intent (an unparseable value is NOT a report) is the whole
      # point of the branch. The NON-equivalent mutation of this line -- writing
      # `true` -- is M04 in scripts/mutate-expand-archive-boundary-support.sh
      # and is killed, so the line itself is covered.
      result.childExitReported = false

proc windowsPowerShellRoot*(systemRoot: string): string =
  ## ``%SystemRoot%\System32\WindowsPowerShell\v1.0`` -- the Windows PowerShell
  ## 5.1 (Desktop edition) install root, which is an OS component and therefore
  ## present at a fixed location on every Windows host.
  let root =
    if systemRoot.len > 0: systemRoot
    else: WindowsPowerShellFallbackSystemRoot
  winJoin(root, "System32", "WindowsPowerShell", "v1.0")

proc windowsPowerShellExe*(systemRoot: string): string =
  ## The Desktop-edition interpreter, named absolutely.
  ##
  ## The fixture half of the boundary gate resolves its shell explicitly rather
  ## than letting ``poUsePath`` pick whatever ``powershell`` currently means:
  ## the CI step shell on this runner class is ``C:\pwsh\pwsh.EXE``, and a
  ## harness that cannot say which interpreter ran its ACL calls cannot explain
  ## why they failed. (The PRODUCTION argv under test still spawns the bare name
  ## ``powershell`` exactly as ``buildZipArgvWindows`` emits it -- that
  ## resolution is part of what the gate exists to check, and must not be
  ## second-guessed by the harness.)
  winJoin(windowsPowerShellRoot(systemRoot), "powershell.exe")

proc windowsPowerShellModulePath*(systemRoot, programFiles,
                                  userProfile: string): string =
  ## Windows PowerShell's DEFAULT module search path, rebuilt from scratch.
  ##
  ## Rebuilt, not filtered and not extended: this proc takes no inherited value
  ## because there is no inherited value worth keeping. The pwsh 7 step shell
  ## exports a ``PSModulePath`` whose ``$PSHOME\Modules`` entry holds
  ## Core-edition copies of the very modules Desktop edition needs, and those
  ## copies win the search. Handing Desktop edition its own three directories
  ## and nothing else is the only composition that cannot be poisoned by
  ## whatever launched us.
  var parts: seq[string]
  if userProfile.len > 0:
    parts.add(winJoin(userProfile, "Documents", "WindowsPowerShell", "Modules"))
  let programFilesRoot =
    if programFiles.len > 0: programFiles
    else: WindowsPowerShellFallbackProgramFiles
  parts.add(winJoin(programFilesRoot, "WindowsPowerShell", "Modules"))
  parts.add(winJoin(windowsPowerShellRoot(systemRoot), "Modules"))
  parts.join(";")

proc foreignModulePathEntries*(inherited, systemRoot, programFiles,
                               userProfile: string): seq[string] =
  ## The entries of an inherited ``PSModulePath`` that do NOT belong to Windows
  ## PowerShell (Desktop edition).
  ##
  ## Purely diagnostic: it is what the preflight prints when
  ## ``Microsoft.PowerShell.Security`` still refuses to load, so the next reader
  ## sees ``C:\pwsh\Modules`` named in the failure instead of having to infer it
  ## from "the module could not be loaded". Comparison is case-insensitive and
  ## separator-normalised because Windows paths arrive in both shapes.
  var roots: seq[string]
  roots.add(windowsPowerShellRoot(systemRoot))
  let programFilesRoot =
    if programFiles.len > 0: programFiles
    else: WindowsPowerShellFallbackProgramFiles
  roots.add(winJoin(programFilesRoot, "WindowsPowerShell"))
  if userProfile.len > 0:
    roots.add(winJoin(userProfile, "Documents", "WindowsPowerShell"))
  proc canon(value: string): string =
    value.replace("/", "\\").strip().toLowerAscii()
  var canonRoots: seq[string]
  for root in roots:
    canonRoots.add(canon(root))
  for rawEntry in inherited.split(';'):
    let entry = rawEntry.strip()
    if entry.len == 0:
      continue
    let candidate = canon(entry)
    var owned = false
    for root in canonRoots:
      if candidate == root or candidate.startsWith(root & "\\"):
        owned = true
        # DECLARED MUTATION SURVIVOR (S01): deleting this `break` is an
        # equivalent mutant. The loop only sets a flag and never reads it
        # again, so no assertion can distinguish the two. Kept because it is
        # the shape a reader expects; recorded here so the survivor is
        # evidence rather than an unexplained gap.
        break
    if not owned:
      result.add(entry)
