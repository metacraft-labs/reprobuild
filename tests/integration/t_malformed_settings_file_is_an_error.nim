## A settings file that exists but does not parse is an error, never "absent".
##
## Workspace-Settings-Files.md §4: the settings files' `[[manifest]]` layers
## compose with the root, and "every genuine layer failure — unreachable,
## unparsable, a conflicting declaration — is still an error". A
## `repro-workspace.toml` (or `repro-workspace.local.toml`) that the strict
## reader rejects is such a failure: the operator declared a layer and it is
## not being applied. The routing probe used to catch the reader's error and
## answer "no layers", which sent every verb to the single-project ladder: a
## typo in a layer entry silently dropped the partner layer's repos from
## `sync`, `status`, `list` and `enable`, all with exit 0.
##
## The fixture is a real workspace root: `projects/demo.toml` declares `core`,
## and a `local_path = "../partner"` layer adds `pextra` to `demo`. Every leg
## runs the REAL `repro` binary and checks that the verb exits non-zero with
## the strict reader's diagnostic, which names the file and the offending key
## (or the line and column of a TOML syntax error):
##
##   1. An unknown key in the shared file's `[[manifest]]` entry, in a
##      workspace whose state already records `demo`: `repro sync --dry-run`,
##      `repro workspace list demo`, `repro ws status` and
##      `repro ws enable demo` each fail naming `repro-workspace.toml` and
##      `manifest[0].bogus`; `enable` leaves the state file byte-identical.
##   2. The same file in a fresh root with no state yet: `workspace list demo`
##      and `ws enable demo` fail the same way, and `enable` writes no state.
##   3. A TOML syntax error in the shared file: the same four verbs fail
##      naming the file and the `(line, column)` of the error.
##   4. A valid shared file with a malformed `repro-workspace.local.toml` (an
##      unknown key in its `[[manifest]]` entry): the same four verbs fail
##      naming the LOCAL file and `manifest[0].bogus`.
##   5. `repro health` is the other deliberate exception, and it is loud: it
##      keeps diagnosing the remaining layers (CLI/health.md: it localizes the
##      problem) with the settings layers set aside, prints its whole report
##      (`--json`: a valid document), and reports the file and key in a failing
##      `workspace-settings` row; it exits non-zero.
##   6. `repro prompt` — decided behaviour, per CLI/prompt.md ("each read is
##      defensive ... degrades to a partial segment rather than breaking the
##      shell"): the prompt never reads the settings files, and an unreadable
##      state file only costs it the branch. With a malformed settings file,
##      and again with a malformed state file, it exits 0, writes nothing to
##      stderr, and prints one segment line starting `[ws`. The verbs the
##      operator runs are the ones that fail loudly.
##   7. A malformed STATE file (an unknown key inside its `[workspace]`
##      table): `sync --dry-run`, `workspace list`, `ws status` and
##      `ws enable demo` fail naming the file and `workspace.bogus` — the
##      table and the key, which the TOML library's own error does not give —
##      and never the unrelated "unescaped backslash" hint; `health` reports it
##      in a failing `workspace-state` row with its whole report (text and
##      `--json`); the prompt stays quiet.
##   8. A key differing from a declared one only in case (`Project` in the
##      state file's `[workspace]`, `Name` in a fragment's `[repo]`): the
##      decoder is case-sensitive and rejects it, and the diagnostic names it
##      (`workspace.Project` from `workspace list` and from health's
##      `workspace-state` row; `repo.Name` from `workspace list demo`).
##
## What each assertion guards. The exit-code and diagnostic assertions of
## legs 1, 3 and 4 fail when `isCompositionalWorkspaceToml` swallows the
## reader's error and answers `false` (measured: `sync --dry-run` then exits
## 0 and plans `core` alone). `enable`'s assertions fail when `enable`
## tolerates the malformed file inside the resolution step that also
## tolerates an unreachable manifest (it then records membership and exits
## 0). The "no state written / unchanged" checks guard that the refusal comes
## before any write. Leg 7's `workspace.bogus` assertions fail when the strict
## decoder reports only what the TOML library says (measured: an EMPTY
## message for a key inside a table, so neither the key nor the table was
## named); its health assertions fail when `health` lets the state reader's
## error escape (measured: exit 1, an error on stderr, no report on stdout).
## Leg 8 fails when the key locator compares keys ignoring case/style while
## the decoder does not (measured: "TOML parser raised with no message", no
## key).
##
## No mocks. Skip rule: skip only when `git` is missing from PATH (the
## member repositories are real `file://` remotes).

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/reasoned_skip

proc q(value: string): string = quoteShell(value)

proc reproBinary(): string =
  requireBinary(currentSourcePath().parentDir.parentDir.parentDir / "build" /
    "bin" / addFileExt("repro", ExeExt), "reprobuild.apps.repro")

proc runRepro(args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  ## The real binary's exit code, stdout and stderr, read separately.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  # The fixture's settings files must be found by discovery, not by an
  # inherited override pointing elsewhere.
  env.del("REPRO_WORKSPACE_CONFIG")
  let p = startProcess(reproBinary(), args = @args, env = env, options = {})
  let o = p.outputStream.readAll()
  let e = p.errorStream.readAll()
  result = (code: p.waitForExit(), stdout: o, stderr: e)
  p.close()

proc requireSuccess(command: string) =
  let res = execCmdEx(command)
  if res.exitCode != 0:
    checkpoint("command failed: " & command & "\n" & res.output)
    quit 1

proc seedBareRepo(gitBin, scratch, barePath: string) =
  ## A bare repository with one commit on `main`.
  let work = scratch / ("seed-" & extractFilename(barePath))
  requireSuccess(q(gitBin) & " init -q -b main " & q(work))
  requireSuccess(q(gitBin) & " -C " & q(work) &
    " config user.email tester@example.invalid")
  requireSuccess(q(gitBin) & " -C " & q(work) & " config user.name Tester")
  writeFile(work / "README", "fixture\n")
  requireSuccess(q(gitBin) & " -C " & q(work) & " add -A")
  requireSuccess(q(gitBin) & " -C " & q(work) & " commit -q -m fixture")
  requireSuccess(q(gitBin) & " clone -q --bare " & q(work) & " " & q(barePath))

proc projectToml(fetch, repo: string): string =
  "schema = \"reprobuild.workspace.project.v1\"\n\nincludes = [\"repos/" &
    repo & ".toml\"]\n\n[project]\nname = \"demo\"\n" &
    "default_revision = \"main\"\ntrunk = \"main\"\n\n[[remote]]\n" &
    "name = \"acme\"\nfetch = \"" & fetch & "\"\n"

proc fragmentToml(name: string): string =
  "schema = \"reprobuild.workspace.repo.v2\"\n\n[repo]\nname = \"" & name &
    "\"\npath = \"" & name & "\"\nremote = \"acme\"\nmainline = \"main\"\n"

const
  validSettings = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[[manifest]]\nlocal_path = \"../partner\"\nvisibility = \"public\"\n"
  unknownKeySettings = validSettings & "bogus = 1\n"
  syntaxErrorSettings = "schema = \"reprobuild.workspace.settings.v1\"\n\n" &
    "[[manifest\nlocal_path = \"../partner\"\n"
  unknownKeyLocal = "schema = \"reprobuild.workspace.settings-local.v1\"\n\n" &
    "[[manifest]]\nlocal_path = \"../partner\"\nvisibility = \"public\"\n" &
    "bogus = 1\n"

proc seedRoot(base, fetch: string): string =
  ## `<base>/ws` declares `demo` = `core`; `<base>/partner` adds `pextra` to
  ## `demo`. Returns the workspace root. No settings file, no state.
  result = base / "ws"
  let partner = base / "partner"
  createDir(result / "projects")
  createDir(result / "repos")
  writeFile(result / "projects" / "demo.toml", projectToml(fetch, "core"))
  writeFile(result / "repos" / "core.toml", fragmentToml("core"))
  createDir(partner / "projects")
  createDir(partner / "repos")
  writeFile(partner / "projects" / "demo.toml", projectToml(fetch, "pextra"))
  writeFile(partner / "repos" / "pextra.toml", fragmentToml("pextra"))

proc stateFile(root: string): string =
  root / ".repro" / "workspace-state.toml"

proc checkRefused(label: string; res: tuple[code: int; stdout, stderr: string];
                  file, detail: string) =
  ## The verb failed, and its diagnostic names `file` and `detail` (the key,
  ## or the line and column).
  checkpoint(label & " exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  check res.code != 0
  check file in res.stderr
  check detail in res.stderr
  check "neither was present" notin res.stderr

proc namesLineAndColumn(text: string): bool =
  ## Whether `text` carries a parser position: `(<line>, <column>)`.
  var i = text.find('(')
  while i >= 0:
    var j = i + 1
    var digits = 0
    while j < text.len and text[j] in Digits:
      inc j; inc digits
    if digits > 0 and text.continuesWith(", ", j):
      var k = j + 2
      var colDigits = 0
      while k < text.len and text[k] in Digits:
        inc k; inc colDigits
      if colDigits > 0 and k < text.len and text[k] == ')':
        return true
    i = text.find('(', i + 1)
  false

proc checkRefusedAt(label: string;
                    res: tuple[code: int; stdout, stderr: string];
                    file: string) =
  ## As `checkRefused`, for a TOML syntax error: the diagnostic names the
  ## file and the `(line, column)` the parser stopped at.
  checkpoint(label & " exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  check res.code != 0
  check file in res.stderr
  check namesLineAndColumn(res.stderr)
  check "neither was present" notin res.stderr

proc checkHealthRow(label, root, rowName, file, key: string) =
  ## `repro health` reports the malformed file as a failing `rowName` row
  ## naming `file` and `key`, emits its WHOLE report (a valid JSON document
  ## with the other layers' rows, and the same row in the text form), and
  ## exits non-zero.
  let res = runRepro(["health", "--json", "--workspace-root=" & root])
  checkpoint(label & " health --json exit=" & $res.code & "\nstdout: " &
    res.stdout & "\nstderr: " & res.stderr)
  check res.code != 0
  var doc: JsonNode
  try:
    doc = parseJson(res.stdout)
  except CatchableError:
    checkpoint(label & ": health --json printed no JSON document")
    check false
    return
  var rows: seq[JsonNode]
  for row in doc["checks"]:
    if row["name"].getStr() == rowName:
      rows.add(row)
  check doc["checks"].len > 5   # the other layers were still diagnosed
  check rows.len == 1
  if rows.len == 1:
    check rows[0]["status"].getStr() == "fail"
    let detail = rows[0]["detail"].getStr()
    check file in detail
    check key in detail
  let text = runRepro(["health", "--workspace-root=" & root])
  checkpoint(label & " health exit=" & $text.code & "\nstdout: " &
    text.stdout & "\nstderr: " & text.stderr)
  check text.code != 0
  check rowName in text.stdout
  check key in text.stdout
  # No row repeats the "neither was present" claim about a file that exists.
  check "neither was present" notin res.stdout
  check "neither was present" notin text.stdout

proc checkPromptQuiet(label: string; root: string) =
  let res = runRepro(["prompt", "--workspace-root=" & root])
  checkpoint(label & " prompt exit=" & $res.code & "\nstdout: " & res.stdout &
    "\nstderr: " & res.stderr)
  check res.code == 0
  check res.stderr == ""
  check res.stdout.strip().splitLines().len == 1
  check res.stdout.startsWith("[ws")

suite "a malformed settings file is an error":

  test "t_malformed_settings_file_is_an_error":
    let gitBin = findExe("git")
    if gitBin.len == 0:
      skip("git is not on PATH — the member repositories are real bare " &
        "repositories, and the verbs under test resolve real remotes")
    else:
      let scratch = createTempDir("repro-malformed-settings-", "")
      defer: removeDir(scratch)
      let remotes = scratch / "remotes"
      createDir(remotes)
      seedBareRepo(gitBin, scratch, remotes / "core")
      seedBareRepo(gitBin, scratch, remotes / "pextra")
      let fetch = fileUrl(remotes)

      proc recordedRoot(name: string): string =
        ## A root whose state records `demo`, written by `enable` while the
        ## settings file was still valid — the state a typo lands in.
        result = seedRoot(scratch / name, fetch)
        writeFile(result / "repro-workspace.toml", validSettings)
        let enabled = runRepro(["workspace", "enable", "demo", "--no-sync",
          "--workspace-root=" & result])
        checkpoint("seed enable: " & enabled.stdout & enabled.stderr)
        require enabled.code == 0
        require fileExists(stateFile(result))
        # Control: with the valid file the partner layer's repo is planned.
        let planned = runRepro(["sync", "--dry-run",
          "--workspace-root=" & result])
        checkpoint("control sync: " & planned.stdout & planned.stderr)
        require planned.code == 0
        require "pextra" in planned.stdout

      proc checkFourVerbs(label, root, file, detail: string;
                          syntaxError = false) =
        let stateBefore = readFile(stateFile(root))
        let results = [
          ("sync --dry-run", runRepro(["sync", "--dry-run",
            "--workspace-root=" & root])),
          ("workspace list demo", runRepro(["workspace", "list", "demo",
            "--workspace-root=" & root])),
          ("ws status", runRepro(["ws", "status",
            "--workspace-root=" & root])),
          ("ws enable demo", runRepro(["ws", "enable", "demo", "--no-sync",
            "--workspace-root=" & root]))]
        for (verb, res) in results:
          if syntaxError:
            checkRefusedAt(label & ": " & verb, res, file)
          else:
            checkRefused(label & ": " & verb, res, file, detail)
        # The refusal comes before any write.
        check readFile(stateFile(root)) == stateBefore

      # Leg 1 — unknown key in a shared `[[manifest]]` entry, state recorded.
      let unknownRoot = recordedRoot("unknown-key")
      writeFile(unknownRoot / "repro-workspace.toml", unknownKeySettings)
      checkFourVerbs("unknown key", unknownRoot,
        unknownRoot / "repro-workspace.toml", "manifest[0].bogus")

      # Leg 2 — the same file in a fresh root with no state yet.
      let freshRoot = seedRoot(scratch / "fresh", fetch)
      writeFile(freshRoot / "repro-workspace.toml", unknownKeySettings)
      checkRefused("fresh: workspace list demo", runRepro(["workspace",
        "list", "demo", "--workspace-root=" & freshRoot]),
        freshRoot / "repro-workspace.toml", "manifest[0].bogus")
      checkRefused("fresh: ws enable demo", runRepro(["ws", "enable", "demo",
        "--no-sync", "--workspace-root=" & freshRoot]),
        freshRoot / "repro-workspace.toml", "manifest[0].bogus")
      check not fileExists(stateFile(freshRoot))
      check not fileExists(freshRoot / ".repro" / "workspace.toml")

      # Leg 3 — a TOML syntax error in the shared file.
      let syntaxRoot = recordedRoot("syntax")
      writeFile(syntaxRoot / "repro-workspace.toml", syntaxErrorSettings)
      checkFourVerbs("syntax error", syntaxRoot,
        syntaxRoot / "repro-workspace.toml", "", syntaxError = true)

      # Leg 4 — a valid shared file, a malformed local file.
      let localRoot = recordedRoot("local")
      writeFile(localRoot / "repro-workspace.local.toml", unknownKeyLocal)
      checkFourVerbs("local file", localRoot,
        localRoot / "repro-workspace.local.toml", "manifest[0].bogus")

      # Leg 5 — `repro health` keeps diagnosing but does not stay quiet: it
      # reports the malformed settings file as a failing `workspace-settings`
      # row naming the file and the key, and fails overall.
      checkHealthRow("malformed settings", unknownRoot, "workspace-settings",
        unknownRoot / "repro-workspace.toml", "manifest[0].bogus")

      # Leg 6 — the prompt stays quiet with a malformed settings file.
      checkPromptQuiet("malformed settings", unknownRoot)

      # Leg 7 — a malformed STATE file (an unknown key inside `[workspace]`):
      # every verb names the file AND the key (`workspace.bogus`), never the
      # unrelated backslash hint; `health` reports a failing `workspace-state`
      # row and still emits its whole report; the prompt stays quiet.
      let stateRoot = recordedRoot("state")
      writeFile(stateFile(stateRoot),
        "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
        "project = \"demo\"\nbogus = 1\n")
      for args in [@["sync", "--dry-run"], @["workspace", "list"],
                   @["ws", "status"], @["ws", "enable", "demo", "--no-sync"]]:
        let res = runRepro(args & @["--workspace-root=" & stateRoot])
        checkRefused("malformed state: " & args.join(" "), res,
          stateFile(stateRoot), "workspace.bogus")
        check "unescaped backslash" notin res.stderr
      checkHealthRow("malformed state", stateRoot, "workspace-state",
        stateFile(stateRoot), "workspace.bogus")
      checkPromptQuiet("malformed state", stateRoot)

      # Leg 8 — a key that differs from a declared one only in case. The
      # decoder is case-sensitive, so `Project` is an unknown key, and it must
      # be named as one: in the state file (by a verb and by health) and in a
      # repo fragment.
      let caseRoot = recordedRoot("case")
      let validState = readFile(stateFile(caseRoot))
      writeFile(stateFile(caseRoot),
        "schema = \"reprobuild.workspace.state.v1\"\n\n[workspace]\n" &
        "Project = \"demo\"\n")
      let caseList = runRepro(["workspace", "list",
        "--workspace-root=" & caseRoot])
      checkRefused("state `Project`: workspace list", caseList,
        stateFile(caseRoot), "workspace.Project")
      check "raised with no message" notin caseList.stderr
      checkHealthRow("state `Project`", caseRoot, "workspace-state",
        stateFile(caseRoot), "workspace.Project")
      writeFile(stateFile(caseRoot), validState)
      writeFile(caseRoot / "repos" / "core.toml",
        fragmentToml("core").replace("\nname = ", "\nName = "))
      let fragmentList = runRepro(["workspace", "list", "demo",
        "--workspace-root=" & caseRoot])
      checkRefused("fragment `Name`: workspace list demo", fragmentList,
        caseRoot / "repos" / "core.toml", "repo.Name")
      check "raised with no message" notin fragmentList.stderr
