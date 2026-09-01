## Cross-platform arm of the M3f Windows execution-boundary gate.
##
## The gate itself (``windows_expand_archive_execution_boundary.nim``) can only
## run on ``eph-win-x64``, where a job waits 45 minutes to three hours for a
## runner. This file executes everywhere, and it is where the two contracts the
## gate got wrong are actually pinned:
##
##   * an observer that dies before reading the child's exit code must not be
##     readable as "the child failed and created no scratch file";
##   * a fixture PowerShell must be handed Windows PowerShell's own module
##     search path, never PowerShell 7's.
##
## Test-double policy: no mocks and no doubles. Every proc under test here is
## pure string composition, so the arguments ARE the real inputs -- the poisoned
## ``PSModulePath`` below is the literal value a pwsh 7 step shell exports, and
## the aborted-observer transcript is the literal shape captured from CI run
## 33316135218.
##
## ASSERTION BUDGET. Every assertion below goes through ``counted``, and the
## final case asserts the total. A deleted or unreachable assertion changes the
## total and reddens that case, so this file cannot quietly shrink -- which is
## the failure mode the whole campaign is about.
##
## MUTATION COVERAGE. ``scripts/mutate-expand-archive-boundary-support.sh``
## applies fourteen single-edit mutations to
## ``tests/windows/expand_archive_boundary_support.nim`` and requires each one
## to redden the named case below. Declared survivors are recorded at the
## mutation site in the module and listed by that script.

import std/[strutils, unittest]

import ./expand_archive_boundary_support

const
  ExpectedCountedAssertions = 41
    ## Pinned deliberately. See ASSERTION BUDGET above.

  # The literal PSModulePath a PowerShell 7 step shell exports on the
  # ``eph-win-x64`` image, where ``$PSHOME`` is ``C:\pwsh``. The first two
  # entries are the poison: they hold Core-edition manifests
  # (``CompatiblePSEditions = @("Core")``) of the very modules Desktop edition
  # autoloads, and they sort ahead of the Desktop directory.
  PoisonedModulePath =
    "C:\\Users\\runner\\Documents\\PowerShell\\Modules;" &
    "C:\\pwsh\\Modules;" &
    "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules"

  SystemRoot = "C:\\Windows"
  ProgramFiles = "C:\\Program Files"
  UserProfile = "C:\\Users\\runner"

var countedAssertions = 0

template counted(condition: untyped) =
  ## Assert and count. The counter is what makes the budget case above a real
  ## check rather than a comment.
  inc countedAssertions
  check condition

suite "M3f boundary support — observer report parsing":

  test "a marker line reports its value":
    let found = taggedValue("SCRATCH=C:\\t\\a.zip", ObserverScratchTag)
    counted found.found
    counted found.value == "C:\\t\\a.zip"

  test "a marker must begin its line":
    # PowerShell's own error rendering is interleaved into the same stream, and
    # it quotes the command it failed in. A marker matched anywhere in a line
    # would let an error message about SCRATCH= become a scratch report.
    counted not taggedValue("noise SCRATCH=x", ObserverScratchTag).found
    counted not taggedValue("xSCRATCH=y", ObserverScratchTag).found

  test "the last marker line wins":
    counted taggedValue("SCRATCH=a\nSCRATCH=b", ObserverScratchTag).value == "b"

  test "CRLF and leading whitespace do not hide a marker":
    counted taggedValue("\r\n  SCRATCH=a\r\n", ObserverScratchTag).value == "a"

  test "a reported child exit of zero is not the same as no report at all":
    # The exact distinction the CI failure turned on: both states carry
    # childExit == 0, and only the flag separates them.
    let reported = parseObserverReport("CHILD_EXIT=0")
    counted reported.childExitReported
    counted reported.childExit == 0
    let silent = parseObserverReport("")
    counted not silent.childExitReported
    counted silent.childExit == 0

  test "a non-numeric child exit is not a report":
    # The observer prints a placeholder when `&` never launched the child.
    counted not parseObserverReport("CHILD_EXIT=unlaunched").childExitReported
    counted not parseObserverReport("CHILD_EXIT=").childExitReported

  test "a negative child exit is preserved":
    let report = parseObserverReport("CHILD_EXIT=-1")
    counted report.childExitReported
    counted report.childExit == -1

  test "a complete observer transcript reports both markers":
    let transcript =
      "Expand-Archive : the archive is invalid\r\n" &
      "SCRATCH=C:\\t\\repro-expand-archive-4242.zip\r\n" &
      "CHILD_EXIT=1\r\n"
    let report = parseObserverReport(transcript)
    counted report.scratchReported
    counted report.scratchPath == "C:\\t\\repro-expand-archive-4242.zip"
    counted report.childExitReported
    counted report.childExit == 1

  test "an aborted observer reports neither marker":
    # The captured shape of the real failure: the observer took a terminating
    # error at the `&` and exited non-zero without ever calling Wait-Event.
    # Reading its exit code as the CHILD's is what made a green
    # `exitCode != 0` sit next to a red `scratchPath.len > 0`.
    let aborted =
      "Expand-Archive : The archive file is corrupted\r\n" &
      "At line:1 char:1\r\n" &
      "+ $ErrorActionPreference = 'Stop'; ...\r\n"
    let report = parseObserverReport(aborted)
    counted not report.scratchReported
    counted not report.childExitReported
    counted report.scratchPath.len == 0

suite "M3f boundary support — Windows PowerShell path composition":

  test "winJoin composes exactly one backslash between segments":
    counted winJoin("C:\\Windows", "System32") == "C:\\Windows\\System32"
    counted winJoin("C:\\", "System32") == "C:\\System32"
    counted winJoin("C:\\Windows", "", "System32") == "C:\\Windows\\System32"
    # The trailing-empty case is the one that distinguishes "skip empty
    # segments" from "rely on the trailing-separator guard": for an INTERIOR
    # empty segment the two are indistinguishable.
    counted winJoin("C:\\Windows", "") == "C:\\Windows"

  test "the fixture interpreter is named absolutely, not left to PATH":
    # `poUsePath` with the bare name `powershell` is what the PRODUCTION argv
    # does, deliberately. The FIXTURE must not: on this runner class the step
    # shell is C:\pwsh\pwsh.EXE, and a harness that cannot say which
    # interpreter ran its ACL calls cannot explain why they failed.
    counted windowsPowerShellExe(SystemRoot) ==
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    counted windowsPowerShellExe("D:\\Win") ==
      "D:\\Win\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"
    counted windowsPowerShellExe("").startsWith("C:\\Windows\\System32\\")

  test "the module path is Desktop edition's own three directories, in order":
    let entries = windowsPowerShellModulePath(
      SystemRoot, ProgramFiles, UserProfile).split(';')
    counted entries.len == 3
    counted entries[0] ==
      "C:\\Users\\runner\\Documents\\WindowsPowerShell\\Modules"
    counted entries[1] == "C:\\Program Files\\WindowsPowerShell\\Modules"
    counted entries[2] ==
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\Modules"

  test "the module path drops the user entry when USERPROFILE is unset":
    counted windowsPowerShellModulePath(
      SystemRoot, ProgramFiles, "").split(';').len == 2

  test "the module path cannot inherit a PowerShell 7 module directory":
    # The defect, stated as an assertion. `windowsPowerShellModulePath` takes
    # no inherited value at all, so there is nothing for a pwsh entry to
    # survive in -- and this case is what refuses a future "helpfully append
    # the inherited path" edit.
    let composed = windowsPowerShellModulePath(
      SystemRoot, ProgramFiles, UserProfile)
    counted not composed.contains("C:\\pwsh\\Modules")
    counted not composed.toLowerAscii().contains(
      "\\documents\\powershell\\modules")

  test "foreign entries name the PowerShell 7 directories of an inherited path":
    let foreign = foreignModulePathEntries(
      PoisonedModulePath, SystemRoot, ProgramFiles, UserProfile)
    counted foreign.len == 2
    counted "C:\\pwsh\\Modules" in foreign
    counted "C:\\Users\\runner\\Documents\\PowerShell\\Modules" in foreign

  test "a Desktop entry is not foreign whatever its case or separator":
    let desktopish =
      "c:/windows/system32/windowspowershell/v1.0/modules;" &
      "C:\\PROGRAM FILES\\WindowsPowerShell\\Modules;" &
      "C:\\Users\\runner\\Documents\\WindowsPowerShell\\Modules"
    counted foreignModulePathEntries(
      desktopish, SystemRoot, ProgramFiles, UserProfile).len == 0

  test "an inherited path that is empty or all separators has no entries":
    counted foreignModulePathEntries(
      "", SystemRoot, ProgramFiles, UserProfile).len == 0
    counted foreignModulePathEntries(
      ";; ;", SystemRoot, ProgramFiles, UserProfile).len == 0

  test "every counted assertion above actually ran":
    # The budget. A deleted assertion, or a case that stopped being reached,
    # changes this number rather than silently shrinking the file's coverage.
    check countedAssertions == ExpectedCountedAssertions
