## M61 gate: `e2e_repro_home_intent_commands`.
##
## Normative description (from `Reprobuild-Development.milestones.org`):
##
##   `repro home add fd` writes `fd` into `activity default:`.
##   `repro home add darktable --activity photography` writes into the
##   named activity (creating it if absent). `repro home add
##   windows-terminal --when windows` finds-or-creates the `when
##   windows:` block inside `activity default:`. `repro home add
##   raspi-tools --if "linux and arm64"` creates an `if linux and
##   arm64:` block when no matching block exists; a subsequent
##   `repro home add another-pkg --when "arm64 and linux"` finds the
##   existing block (predicate-normalized match) and appends, keeping
##   the existing `if` keyword. `repro home remove fd` removes the
##   line; `--activity`, `--when`, and `--if` flags scope the removal.
##   `repro home enable develop_software` adds the activity to the
##   current host's entry in `hosts:`; `--host other-machine` edits
##   that host's entry instead and makes no other changes. An attempt
##   to `disable default` fails closed. `repro home why fd` traces
##   through activity, predicate, and host assignment.
##
## The gate drives the real `repro` binary (the same one users will run).
## Per spec, the only allowed mock is the fixture profile directory.

import std/[os, osproc, streams, strtabs, strutils, unittest]

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-intent"

const ProjectRoot = currentSourcePath().parentDir().parentDir().parentDir().parentDir()

proc reproBinary(): string =
  ## Locate the real `repro` executable. The build script writes it to
  ## `build/bin/repro(.exe)` from `apps/repro/repro.nim`.
  let exeName = when defined(windows): "repro.exe" else: "repro"
  let candidate = ProjectRoot / "build" / "bin" / exeName
  doAssert fileExists(candidate),
    "repro binary not found at " & candidate &
    "; build with `just build` first"
  candidate

proc tmpDir(name: string): string =
  result = getTempDir() / "repro-home-m61" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc copyFixture(name, intoDir: string): string =
  result = intoDir / "home.nim"
  let src = FixtureRoot / name
  doAssert fileExists(src), "missing fixture: " & src
  copyFile(src, result)

proc runRepro(profileDir: string; host: string;
              args: openArray[string]; catalog: string = "*"):
    tuple[exitCode: int; stdoutText, stderrText: string] =
  ## Invoke `repro home <args...>` with the fixture profile dir wired
  ## via `$REPRO_HOME_PROFILE_DIR`, the host via `$REPRO_HOST`, and the
  ## package catalog via `$REPRO_HOME_PACKAGE_CATALOG`. Passing
  ## `catalog="*"` (the default) clears the env var, which the CLI
  ## treats as "accept any package".
  let bin = reproBinary()
  var fullArgs = @["home"]
  for a in args: fullArgs.add a
  # Inherit the parent env, then layer overrides on top.
  var envTable: seq[tuple[key, value: string]]
  for key, value in envPairs():
    envTable.add (key, value)
  proc setVar(k, v: string) =
    var replaced = false
    for i in 0 ..< envTable.len:
      if envTable[i].key == k:
        envTable[i].value = v
        replaced = true
        break
    if not replaced:
      envTable.add (k, v)
  proc dropVar(k: string) =
    for i in 0 ..< envTable.len:
      if envTable[i].key == k:
        envTable.delete(i)
        return
  setVar("REPRO_HOME_PROFILE_DIR", profileDir)
  setVar("REPRO_HOST", host)
  if catalog == "*":
    dropVar("REPRO_HOME_PACKAGE_CATALOG")
  else:
    setVar("REPRO_HOME_PACKAGE_CATALOG", catalog)
  # Build a process for capturing both streams.
  var processEnv = newStringTable()
  for kv in envTable:
    processEnv[kv.key] = kv.value
  let p = startProcess(bin, args = fullArgs, env = processEnv,
    options = {poUsePath, poStdErrToStdOut})
  let outStream = p.outputStream()
  var combined = ""
  while not outStream.atEnd():
    let chunk = outStream.readAll()
    if chunk.len == 0:
      break
    combined.add chunk
  let code = p.waitForExit()
  p.close()
  result = (exitCode: code, stdoutText: combined, stderrText: combined)

# ---------------------------------------------------------------------------

suite "M61 repro home intent commands":

  test "1. `repro home add fd` writes fd into activity default:":
    let dir = tmpDir("add-default")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop", ["add", "fd"])
    check code == 0
    let body = readFile(path)
    # `fd` lives in the activity default body at indent 4.
    check "    fd" in body
    let defIdx = body.find("  activity default:")
    let fdIdx = body.find("    fd", defIdx)
    check defIdx >= 0
    check fdIdx > defIdx
    # Exactly one line beginning with `    fd`.
    check body.count("    fd") == 1

  test "2. `repro home add darktable --activity photography`":
    let dir = tmpDir("add-named-activity")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "darktable", "--activity", "photography"])
    check code == 0
    let body = readFile(path)
    let actIdx = body.find("  activity photography:")
    let pkgIdx = body.find("    darktable", actIdx)
    check actIdx >= 0
    check pkgIdx > actIdx

  test "3. `repro home add windows-terminal --when windows`":
    let dir = tmpDir("add-when-create")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "windows-terminal", "--when", "windows"])
    check code == 0
    let body = readFile(path)
    # The when block lives inside activity default at indent 4; the body
    # line indents at 6.
    let actIdx = body.find("  activity default:")
    let whenIdx = body.find("    when windows:", actIdx)
    let pkgIdx = body.find("      windows-terminal", whenIdx)
    check actIdx >= 0
    check whenIdx > actIdx
    check pkgIdx > whenIdx

  test "4. `repro home add raspi-tools --if 'linux and arm64'`":
    let dir = tmpDir("add-if-create")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "raspi-tools", "--if", "linux and arm64"])
    check code == 0
    let body = readFile(path)
    # `--if` keyword preserved when CREATING a new block. Canonical
    # operand order is lex-sorted: `arm64 and linux`.
    check "    if arm64 and linux:" in body
    check "    when arm64 and linux:" notin body
    check body.count("if arm64 and linux:") == 1
    let blkIdx = body.find("    if arm64 and linux:")
    let pkgIdx = body.find("      raspi-tools", blkIdx)
    check pkgIdx > blkIdx

  test "5. subsequent `--when 'arm64 and linux'` finds the existing if-block (keyword preserved)":
    let dir = tmpDir("add-when-finds-if")
    let path = copyFixture("cli_seed.nim", dir)
    discard runRepro(dir, "dev-laptop",
      ["add", "raspi-tools", "--if", "linux and arm64"])
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "another-pkg", "--when", "arm64 and linux"])
    check code == 0
    let body = readFile(path)
    # Exactly ONE block exists for this normalized predicate, and the
    # KEYWORD remains `if` (the original).
    check body.count("if arm64 and linux:") == 1
    check body.count("when arm64 and linux:") == 0
    check "      raspi-tools" in body
    check "      another-pkg" in body
    let blkIdx = body.find("    if arm64 and linux:")
    let raspiIdx = body.find("      raspi-tools", blkIdx)
    let anotherIdx = body.find("      another-pkg", blkIdx)
    check raspiIdx > blkIdx
    check anotherIdx > raspiIdx

  test "6. `repro home remove fd` removes the line":
    let dir = tmpDir("remove-default")
    let path = copyFixture("cli_seed.nim", dir)
    discard runRepro(dir, "dev-laptop", ["add", "fd"])
    let before = readFile(path)
    check "    fd" in before
    let (code, output, _) = runRepro(dir, "dev-laptop", ["remove", "fd"])
    check code == 0
    let after = readFile(path)
    check "    fd" notin after
    # Round-trip pattern: removing what add wrote produces a file equal
    # to the pre-add original.
    let pristine = readFile(FixtureRoot / "cli_seed.nim")
    check after == pristine

  test "7a. `--activity` scopes removal":
    let dir = tmpDir("remove-scoped-activity")
    let path = copyFixture("cli_seed.nim", dir)
    # Add `fd` to two activities.
    discard runRepro(dir, "dev-laptop", ["add", "fd"])
    discard runRepro(dir, "dev-laptop",
      ["add", "fd", "--activity", "photography"])
    let after1 = readFile(path)
    check after1.count("    fd") == 2
    # Remove only from `photography`.
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["remove", "fd", "--activity", "photography"])
    check code == 0
    let after2 = readFile(path)
    # `fd` still in default; not in photography.
    check after2.count("    fd") == 1
    let defIdx = after2.find("  activity default:")
    let photoIdx = after2.find("  activity photography:")
    check defIdx >= 0
    check photoIdx > defIdx
    let fdIdx = after2.find("    fd", defIdx)
    check fdIdx > defIdx and fdIdx < photoIdx

  test "7b. `--when`/`--if` scope removal (keyword-blind, predicate-normalized)":
    let dir = tmpDir("remove-scoped-pred")
    let path = copyFixture("cli_seed.nim", dir)
    discard runRepro(dir, "dev-laptop",
      ["add", "raspi-tools", "--if", "linux and arm64"])
    discard runRepro(dir, "dev-laptop", ["add", "raspi-tools"])
    let beforeRm = readFile(path)
    # `raspi-tools` appears in both the bare default body and inside the
    # conditional.
    check beforeRm.count("raspi-tools") == 2
    # Scoped remove via `--when` against the IF block (normalized match):
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["remove", "raspi-tools", "--when", "arm64 and linux"])
    check code == 0
    let after = readFile(path)
    # Only the conditional-scoped occurrence was removed; the bare one
    # survives.
    check after.count("raspi-tools") == 1
    # The bare `raspi-tools` is the one that survived (not inside the
    # if block).
    let bareIdx = after.find("    raspi-tools")
    check bareIdx >= 0

  test "8. `repro home enable develop_software` updates the current host":
    let dir = tmpDir("enable-current-host")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["enable", "develop_software"])
    check code == 0
    let body = readFile(path)
    # dev-laptop already has [photography]; develop_software is appended.
    check "\"dev-laptop\": [photography, develop_software]" in body
    # The other host entry is unchanged.
    check "\"other-machine\": []" in body

  test "9. `--host other-machine` edits ONLY that host's entry":
    let dir = tmpDir("enable-named-host")
    let path = copyFixture("cli_seed.nim", dir)
    let before = readFile(path)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["enable", "develop_software", "--host", "other-machine"])
    check code == 0
    let after = readFile(path)
    # other-machine flipped from [] to [develop_software]; dev-laptop
    # untouched.
    check "\"other-machine\": [develop_software]" in after
    check "\"dev-laptop\": [photography]" in after
    # Defensive: nothing else changed except the one host entry line.
    let beforeLines = before.splitLines()
    let afterLines = after.splitLines()
    check beforeLines.len == afterLines.len
    var diffCount = 0
    for i in 0 ..< beforeLines.len:
      if beforeLines[i] != afterLines[i]:
        inc diffCount
        # The one differing line must be the other-machine entry.
        check "other-machine" in afterLines[i]
    check diffCount == 1

  test "10. `repro home disable default` exits non-zero with the expected diagnostic":
    let dir = tmpDir("disable-default-guard")
    let path = copyFixture("cli_seed.nim", dir)
    let before = readFile(path)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["disable", "default"])
    check code != 0
    check "default" in output
    check "cannot be toggled" in output or "always enabled" in output
    # Profile must be UNTOUCHED.
    let after = readFile(path)
    check after == before

  test "10b. `repro home enable default` also exits non-zero":
    let dir = tmpDir("enable-default-guard")
    let path = copyFixture("cli_seed.nim", dir)
    let before = readFile(path)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["enable", "default"])
    check code != 0
    let after = readFile(path)
    check after == before

  test "11. `repro home why fd` traces activity, predicate, host assignment":
    let dir = tmpDir("why-fd")
    let path = copyFixture("cli_seed.nim", dir)
    discard runRepro(dir, "dev-laptop", ["add", "fd"])
    discard runRepro(dir, "dev-laptop",
      ["add", "fd", "--when", "windows"])
    let (code, output, _) = runRepro(dir, "dev-laptop", ["why", "fd"])
    check code == 0
    # Must mention the activity name `default` and the predicate
    # `windows`, and indicate the host context.
    check "default" in output
    check "windows" in output
    check "dev-laptop" in output

  test "11b. `repro home why` on a not-declared package says so":
    let dir = tmpDir("why-missing")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["why", "no-such-package"])
    check code == 0
    check "no-such-package" in output
    check "NOT declared" in output or "not declared" in output

  test "12. unknown package (configured catalog) exits non-zero":
    let dir = tmpDir("unknown-package")
    let path = copyFixture("cli_seed.nim", dir)
    let before = readFile(path)
    # With an explicit catalog that does NOT include `made-up-pkg`, the
    # add must fail closed.
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "made-up-pkg"], catalog = "fd,neovim,tmux,git")
    check code != 0
    check "made-up-pkg" in output
    # Profile must NOT have been touched.
    let after = readFile(path)
    check after == before

  test "13. `repro home list` reports enabled vs inactive packages":
    let dir = tmpDir("list")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop", ["list"])
    check code == 0
    # Fixture default: neovim, tmux. Fixture photography: exiftool.
    # dev-laptop has [photography], so exiftool is enabled too.
    check "neovim" in output
    check "tmux" in output
    check "exiftool" in output
    check "dev-laptop" in output

  test "14. `--now` on enable is accepted, reports deferred, intent edit still happens":
    let dir = tmpDir("now-deferred")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["enable", "develop_software", "--now"])
    check code == 0
    check "deferred" in output or "M63" in output
    let body = readFile(path)
    check "develop_software" in body

  test "15. `--no-apply` is accepted-but-ignored at M61":
    let dir = tmpDir("no-apply-flag")
    let path = copyFixture("cli_seed.nim", dir)
    let (code, output, _) = runRepro(dir, "dev-laptop",
      ["add", "fd", "--no-apply"])
    check code == 0
    let body = readFile(path)
    check "    fd" in body
