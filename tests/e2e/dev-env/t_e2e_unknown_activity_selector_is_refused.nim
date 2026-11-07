## An `--activity` naming no activity the recipe declares is refused, by
## every activating surface, before anything starts (reprobuild-pm issue
## 2026-10-13-unknown-activity-selector-is-silently-ignored; spec
## CLI/up.md `repro up --activity`, CLI/dev-env.md; the rule's ground is
## Shared-Development-Services.md §7.2 and §10's first criterion).
##
## `e2e_unknown_activity_selector_is_refused`, through the real
## `build/bin/repro` against a real project whose `devEnv:` declares
## `default` and `debug` and gates one record on `reqonly`, which it never
## declares with `activity`:
##
## * `repro exec --activity=bogus -- <cmd>` exits 1 without running `<cmd>`
##   (its marker file is never written), and stderr names `bogus`, the
##   package and every selectable activity; asked again (the dev-env edge
##   now cached) it refuses again;
## * a list with one unknown name (`--activity=debug,bogus`, and the
##   repeated-flag spelling) is refused the same way;
## * `--activity=Debug` is refused with `did you mean `debug``: names
##   compare exactly, as the selection gate compares them, so accepting it
##   would select nothing;
## * `repro shell --print-env=posix --activity=bogus` exits 1 and prints no
##   environment;
## * `repro up --activity bogus` exits 1 and no session record is written.
##
## Positive controls: `default`, `debug` and the requirement-only `reqonly`
## are accepted and switch on what they gate.
##
## Before the fix every refusal above was exit 0: the selector was accepted,
## recorded, and selected nothing.
##
## No mocks: the real binary, a real recipe compiled by the real provider
## compile edge, the real dev-env artifact, real child processes.
## Platforms: every host with an io-monitor backend (Linux, macOS, Windows);
## the commands run through `sh`, so on Windows it needs git's `sh` on PATH
## like its neighbours.

import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

import repro_test_support

proc providerText(): string =
  "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    activity \"debug\"\n" &
    "    setEnv \"APP_BASE\", \"base\"\n" &
    "    setEnv \"DEBUG_ONLY\", \"enabled\", activities = [\"debug\"]\n" &
    "    setEnv \"REQ_ONLY\", \"on\", activities = [\"reqonly\"]\n"

type
  Case = object
    tempRoot, appRoot, repoRoot, reproBin, shim: string

proc prepareCase(): Case =
  result.repoRoot = getCurrentDir()
  result.tempRoot = createTempDir("repro-unknown-activity", "")
  result.appRoot = result.tempRoot / "app"
  createDir(result.appRoot)
  writeFile(result.appRoot / "reprobuild.nim", providerText())
  discard requireSuccess(shellCommand(@["git", "init"]), result.appRoot)
  discard requireSuccess(shellCommand(@["git", "add", "reprobuild.nim"]),
    result.appRoot)
  discard requireSuccess(shellCommand(@[
    "git",
    "-c", "user.email=reprobuild@example.invalid",
    "-c", "user.name=Reprobuild Test",
    "-c", "commit.gpgsign=false",
    "commit", "-m", "fixture"
  ]), result.appRoot)
  result.reproBin = requireBinary(result.repoRoot / "build" / "bin" /
    addFileExt("repro", ExeExt), "reprobuild.apps.repro")
  when isIoMonitorSupported:
    result.shim = prepareMonitorTools(result.repoRoot, result.tempRoot,
      "unknown-activity").shim

proc envFor(c: Case): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  result["REPRO_MONITOR_SHIM_LIB"] = c.shim

proc run(c: Case; args: openArray[string]):
    tuple[code: int; stdout, stderr: string] =
  let res = runProgramSplit(c.reproBin, args, c.repoRoot, c.envFor())
  checkpoint "repro " & args.join(" ") & " (exit " & $res.code &
    ")\n--- stdout\n" & res.stdout & "\n--- stderr\n" & res.stderr
  (res.code, res.stdout, res.stderr)

proc sessionRecords(appRoot: string): seq[string] =
  let root = appRoot / ".repro" / "dev-env"
  if dirExists(root):
    for path in walkDirRec(root):
      if path.extractFilename == "session.json":
        result.add path

const Probe = "printf '%s|%s|%s\\n' \"$APP_BASE\" \"${DEBUG_ONLY-unset}\" " &
  "\"${REQ_ONLY-unset}\""

proc refusalNames(stderr, name: string): bool =
  stderr.contains("activity `" & name & "` is not declared by package " &
    "`fixture`") and
    stderr.contains("the activities it declares are: `default`, `debug`, " &
      "`reqonly`")

suite "dev-env: an unknown activity selector is refused":
  when isIoMonitorSupported:
    test "e2e_unknown_activity_selector_is_refused":
      let c = prepareCase()
      defer: removeDir(c.tempRoot)
      let marker = c.tempRoot / "ran.marker"
      let touch = "touch " & quoteShell(marker)

      # Positive controls first: what the recipe declares is selectable.
      for (selector, expected) in [("default", "base|unset|unset"),
                                   ("debug", "base|enabled|unset"),
                                   ("reqonly", "base|unset|on")]:
        let ok = c.run(["exec", c.appRoot, "--activity=" & selector, "--",
          "sh", "-c", Probe])
        check ok.code == 0
        check ok.stdout.strip() == expected

      # An undeclared name: refused, the command never runs, twice.
      for attempt in 1 .. 2:
        let bogus = c.run(["exec", c.appRoot, "--activity=bogus", "--",
          "sh", "-c", touch])
        check bogus.code == 1
        check refusalNames(bogus.stderr, "bogus")
        check not fileExists(marker)

      # One unknown name in a list.
      for args in [@["--activity=debug,bogus"],
                   @["--activity", "debug", "--activity", "bogus"]]:
        let mixed = c.run(@["exec", c.appRoot] & args & @["--", "sh", "-c",
          touch])
        check mixed.code == 1
        check refusalNames(mixed.stderr, "bogus")
        check not mixed.stderr.contains("activity `debug` is not declared")
        check not fileExists(marker)

      # Spelling: compared exactly, the near miss named.
      let cased = c.run(["exec", c.appRoot, "--activity=Debug", "--",
        "sh", "-c", touch])
      check cased.code == 1
      check refusalNames(cased.stderr, "Debug")
      check cased.stderr.contains("did you mean `debug`?")
      check not fileExists(marker)

      # `repro shell --print-env`: no environment printed.
      let shell = c.run(["shell", "--print-env=posix", "--activity=bogus",
        c.appRoot])
      check shell.code == 1
      check refusalNames(shell.stderr, "bogus")
      check not shell.stdout.contains("APP_BASE")

      # `repro up`: refused before the supervisor, no session record.
      let up = c.run(["up", c.appRoot, "--activity", "bogus",
        "--http=127.0.0.1:0"])
      if up.code == 0:
        discard c.run(["down", c.appRoot, "--activity", "bogus"])
      check up.code == 1
      check refusalNames(up.stderr, "bogus")
      check sessionRecords(c.appRoot).len == 0
