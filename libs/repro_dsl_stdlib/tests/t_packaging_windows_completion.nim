## The Windows packages' PowerShell completion: what the MSI's authoring and
## the Scoop manifest say when their tree carries a completion script, and
## what the PowerShell they run does to a profile file.
##
## The tree here is a staged Windows tree with one completion script added
## by hand, as ``addShellCompletion`` adds it: in a unit test there is no
## provider, so no completion edge, and ``addShellCompletion`` stages
## nothing (``componentCompletionFiles`` is empty outside provider mode).
## That hand-added entry is the one stand-in, justified because the real
## path is the integration test
## ``tests/integration/test_cs_m8d_generated_packages_add_completion.nim``,
## which builds the fixture with ``repro build`` and reads the packages
## back; this file covers the cases that are cheaper to state here: the
## profile writer's handling of files it must not rewrite, and the
## authoring of a package without the script.
##
## The PowerShell cases run the generated code with ``pwsh`` (PowerShell 7)
## with ``-NoProfile``, in a scratch directory, on files the test creates;
## they never read or write a real profile. Without ``pwsh`` on ``PATH``
## they are skipped, naming it, except in a gate run
## (``REPROBUILD_GATE_RUN=1``), where they fail.
##
## MOCKS: the hand-added staged script above; nothing else.

import std/[json, os, strtabs, strutils, tempfiles, unittest]
from std/unicode import runes

import repro_core/process_env
import repro_project_dsl
import repro_test_support
import repro_test_support/reasoned_skip
import repro_dsl_stdlib/packaging

import ./packaging_test_support

const
  Program = "hello"
  ScriptRel = "share/hello/completions/hello.ps1"

proc treeWithScript(withScript = true): StagedTree =
  ## A staged Windows tree of the sample distribution, with the PowerShell
  ## script of ``hello`` where ``windowsShellCompletionLayout`` puts it.
  resetBuildActionRegistry()
  result = stageInstallTree(sampleDistribution(toWindows), "msi")
  if withScript:
    let layout = windowsShellCompletionLayout()
    check layout.powershellDir.replace(CompletionProgramToken, Program) &
      "/" & Program & ".ps1" == ScriptRel
    check layout.bashDir.len == 0 and layout.zshDir.len == 0 and
      layout.fishDir.len == 0
    let edge = result.files[0].edge
    result.files.add(StagedFile(rootRelPath: ScriptRel, edge: edge,
      role: crDataFile))
    result.completions.add(StagedCompletionFile(program: Program,
      shell: "powershell", rootRelPath: ScriptRel))

proc pwshEnv(scratch: string): StringTableRef =
  result = inheritedEnvTable()
  result["HOME"] = scratch
  result["XDG_CONFIG_HOME"] = scratch / ".config"
  result["XDG_DATA_HOME"] = scratch / ".local" / "share"
  result["XDG_CACHE_HOME"] = scratch / ".cache"
  result["POWERSHELL_TELEMETRY_OPTOUT"] = "1"
  result["POWERSHELL_UPDATECHECK"] = "Off"
  result.del("LD_PRELOAD")

proc pwsh(script, scratch: string): tuple[code: int; output: string] =
  ## Runs ``script`` (written to a file) with pwsh.
  let file = scratch / "run.ps1"
  writeFile(file, script)
  let run = runProgramSplit(findExe("pwsh"),
    ["-NoLogo", "-NoProfile", "-NonInteractive", "-File", file], scratch,
    pwshEnv(scratch))
  checkpoint("pwsh -> exit " & $run.code & "\n" & run.stdout & run.stderr)
  (run.code, run.stdout & run.stderr)

template withPwsh(body: untyped) =
  if findExe("pwsh").len == 0:
    if getEnv("REPROBUILD_GATE_RUN") == "1":
      checkpoint("pwsh is not on PATH in a gate run")
      check false
    else:
      skip("pwsh is not on PATH; the generated PowerShell is run with it")
  else:
    body

proc update(scratch, path, script: string): tuple[code: int; output: string] =
  ## ``Update-ClispecCompletionBlock`` on ``path``.
  pwsh(profileBlockUpdater(Program) & "\n" &
    "Write-Output (Update-ClispecCompletionBlock " & powerShellLiteral(path) &
    " " & powerShellLiteral(script) & ")\n", scratch)

suite "packaging: Windows packages register the PowerShell completion":

  test "the MSI has the four actions, around InstallFinalize and RemoveFiles":
    let tree = treeWithScript()
    let wxs = wxsText(tree.dist, tree)
    for id in ["ClispecCompletionEnsure1", "ClispecCompletionRemove1"]:
      check ("<CustomAction Id=\"" & id & "\" BinaryKey=\"WixCA\" " &
        "DllEntry=\"WixQuietExec64\" Execute=\"deferred\" " &
        "Impersonate=\"no\" Return=\"ignore\" />") in wxs
      check ("<CustomAction Id=\"Set" & id & "\" Property=\"" & id &
        "\" Value=\"") in wxs
    check ("<Custom Action=\"ClispecCompletionEnsure1\" " &
      "Before=\"InstallFinalize\">NOT (REMOVE~=\"ALL\")</Custom>") in wxs
    check ("<Custom Action=\"ClispecCompletionRemove1\" " &
      "Before=\"RemoveFiles\">REMOVE~=\"ALL\"</Custom>") in wxs
    # The quiet exec's links come from WixUtilExtension.
    check "WixUtilExtension" in msiExtensions(tree.dist, tree)
    check msiCompletionScripts(tree).len == 1

  test "without a script the MSI has no action and needs no extension for it":
    var dist = sampleDistribution(toWindows, withService = false)
    resetBuildActionRegistry()
    let tree = stageInstallTree(dist, "msi")
    let wxs = wxsText(dist, tree)
    check "CustomAction" notin wxs
    check "InstallExecuteSequence" notin wxs
    check msiExtensions(dist, tree).len == 0

  test "the install action names the script by its file key":
    let tree = treeWithScript()
    let wxs = wxsText(tree.dist, tree)
    var fileId = ""
    for line in wxs.splitLines():
      if "share\\hello\\completions\\hello.ps1" in line and "<File " in line:
        let at = line.find("Id=\"") + 4
        fileId = line[at ..< line.find('"', at)]
    check fileId.len > 0
    # (The .wxs escapes the value's quotes.)
    # The path is in a comment after the marker, never in the code: the
    # install action's command line ends with it, the removal's has none.
    check ("-Command &quot;[ClispecCompletionRun1] " & MsiScriptPathMarker &
      "[#" & fileId & "]&quot;\"") in wxs
    check "-Command &quot;[ClispecCompletionRun1]&quot;\"" in wxs
    check wxs.count(MsiScriptPathMarker) == 1
    check "$s=" notin wxs
    check "[System64Folder]WindowsPowerShell\\v1.0\\powershell.exe" in wxs
    # The script itself is a property both command lines insert.
    check "<Property Id=\"ClispecCompletionRun1\" Value=\" iex (" in wxs

  test "the Scoop manifest carries the hooks only with a script":
    let withHooks = parseJson(scoopManifestText(sampleDistribution(toWindows),
      treeWithScript()))
    check withHooks.hasKey("post_install") and
      withHooks.hasKey("pre_uninstall")
    var post = ""
    for line in withHooks["post_install"]: post.add(line.getStr & "\n")
    check "[IO.Path]::Combine($dir, 'share', 'hello', 'completions', " &
      "'hello.ps1')" in post
    check "GetFolderPath('MyDocuments')" in post
    let without = parseJson(scoopManifestText(sampleDistribution(toWindows),
      treeWithScript(withScript = false)))
    check not without.hasKey("post_install")
    check not without.hasKey("pre_uninstall")

  test "the profile writer adds, replaces and removes only its block":
    withPwsh:
      let scratch = createTempDir("t-windows-completion-", "")
      defer: removeDir(scratch)
      let profile = scratch / "Profile.ps1"
      writeFile(profile, "Set-Alias ll Get-ChildItem\n")
      check update(scratch, profile, "C:\\a\\hello.ps1").output.strip ==
        "written"
      let once = readFile(profile)
      # An ASCII file stays ASCII, with no byte-order mark added.
      check once.startsWith("Set-Alias ll Get-ChildItem\n")
      # The file's own line ending is kept.
      check "\r\n" notin once
      check once.endsWith(completionBlockOpen(Program) & "\n" &
        completionBlockBody(Program, "C:\\a\\hello.ps1") &
        completionBlockClose(Program) & "\n")
      check update(scratch, profile, "C:\\a\\hello.ps1").output.strip ==
        "unchanged"
      # Another path replaces the block rather than adding one.
      check update(scratch, profile, "C:\\b\\hello.ps1").output.strip ==
        "written"
      check readFile(profile).count(completionBlockOpen(Program)) == 1
      check "C:\\b\\hello.ps1" in readFile(profile)
      check update(scratch, profile, "").output.strip == "written"
      # Byte for byte the file it was added to.
      check readFile(profile) == "Set-Alias ll Get-ChildItem\n"
      # A file the block was all of goes when the block does.
      let created = scratch / "new" / "Profile.ps1"
      check update(scratch, created, "C:\\a\\hello.ps1").output.strip ==
        "written"
      check readFile(created).startsWith("\xEF\xBB\xBF" &
        completionBlockOpen(Program))
      check update(scratch, created, "").output.strip == "deleted"
      check not fileExists(created)

  test "a UTF-16 or UTF-8 profile keeps its encoding and its bytes":
    withPwsh:
      let scratch = createTempDir("t-windows-completion-", "")
      defer: removeDir(scratch)
      # Windows PowerShell 5.1's `>` writes UTF-16LE with a byte-order mark.
      proc utf16le(text: string): string =
        result = "\xFF\xFE"
        for r in text.runes:
          doAssert int(r) < 0x10000
          result.add(char(int(r) and 0xFF))
          result.add(char(int(r) shr 8))
      for (name, original, marker) in [
          ("utf16.ps1", utf16le("# caf\u00E9\r\n"), utf16le("# >>> ")[2 .. ^1]),
          ("utf8.ps1", "\xEF\xBB\xBF# caf\xC3\xA9\r\n", "# >>> ")]:
        let profile = scratch / name
        writeFile(profile, original)
        check update(scratch, profile, "C:\\a\\hello.ps1").output.strip ==
          "written"
        let added = readFile(profile)
        check added.startsWith(original)
        check marker in added
        check update(scratch, profile, "C:\\a\\hello.ps1").output.strip ==
          "unchanged"
        check update(scratch, profile, "").output.strip == "written"
        check readFile(profile) == original
      # UTF-32 is left alone.
      let wide = scratch / "utf32.ps1"
      writeFile(wide, "\xFF\xFE\x00\x00#\x00\x00\x00")
      let r = update(scratch, wide, "C:\\a\\hello.ps1")
      check r.code != 0 and "UTF-32" in r.output
      check readFile(wide) == "\xFF\xFE\x00\x00#\x00\x00\x00"

  test "a path holding a quote is quoted in the block":
    withPwsh:
      let scratch = createTempDir("t-windows-completion-", "")
      defer: removeDir(scratch)
      let profile = scratch / "Profile.ps1"
      check update(scratch, profile, "C:\\it's\\hello.ps1").output.strip ==
        "written"
      # (A new file gets Windows line endings.)
      check completionBlockBody(Program, "C:\\it's\\hello.ps1") in
        readFile(profile).replace("\r\n", "\n")
      check "\r\n" in readFile(profile)
      # The typographic quotes PowerShell reads as quotes are doubled too,
      # as clispec quotes them, so the profile still parses.
      let typographic = scratch / "Typographic.ps1"
      let path = "C:\\Bob\u2019s \u2018x\u2019\\hello.ps1"
      check update(scratch, typographic, path).output.strip == "written"
      check completionBlockBody(Program, path) in
        readFile(typographic).replace("\r\n", "\n")
      check pwsh("$ErrorActionPreference = 'Stop'\n. " &
        powerShellLiteral(typographic) & "\n", scratch).code == 0

  test "a profile it cannot read safely is left as it is":
    withPwsh:
      let scratch = createTempDir("t-windows-completion-", "")
      defer: removeDir(scratch)
      # Non-ASCII text without a byte-order mark: Windows PowerShell 5.1
      # reads it in the ANSI code page, which the writer cannot know.
      let ansi = scratch / "ansi.ps1"
      writeFile(ansi, "# caf\xE9\r\n")
      let r1 = update(scratch, ansi, "C:\\a\\hello.ps1")
      check r1.code != 0 and "non-ASCII" in r1.output
      check readFile(ansi) == "# caf\xE9\r\n"
      # A block with no closing line: removing it would drop the rest.
      let open = scratch / "open.ps1"
      let text = completionBlockOpen(Program) & "\r\nuser line\r\n"
      writeFile(open, text)
      let r2 = update(scratch, open, "")
      check r2.code != 0 and "no closing line" in r2.output
      check readFile(open) == text
      # Removing from a file that is not there creates nothing.
      check update(scratch, scratch / "absent.ps1", "").output.strip ==
        "absent"
      check not fileExists(scratch / "absent.ps1")
