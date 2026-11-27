## `nim check` compiles a workspace sibling only as `nim c` would, and never
## a stale one in silence.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (amended 2026-11-22, and 2026-11-27 for evaluations that cannot run
## git). The defect, observed 2026-11-26: the workspace's `../nim-cli-spec` was behind (and did not hold) the
## revision reprobuild pins for it, the development shell's `$CLI_SPEC_SRC`
## named the pinned tree, and the `nim check` sweep of `just lint` compiled
## the sibling, failed on `undeclared identifier`, and nothing named the
## sibling or its pin.
##
## Why: `nim check` (and nimsuggest) evaluate `config.nims` with `gorgeEx`
## answering ("", 0) for every command, so the file's git probes observe
## nothing, the sibling reads as "cannot tell", and "cannot tell" keeps it.
## `nim c` in the same shell runs git, finds the sibling stale and takes the
## pinned tree. Measured 2026-11-27 at reprobuild `agents` 715ac0c88 with the
## development shell's Nim 2.3.1, on exactly the fixture below: `nim c`
## printed "using $CLI_SPEC_SRC=... instead of the sibling" and succeeded;
## `nim check` printed nothing about the sibling and failed on `undeclared
## identifier: 'newApi'`.
##
## Fixture: a workspace whose consumer directory holds reprobuild's own
## `config.nims` (with the shared policy module at the relative path the file
## imports it from, and the lint's `scripts/lib/sibling_verdicts.sh`), a
## `repro.lock` pinning `nim-cli-spec` at revision NEW, and a `../nim-cli-spec`
## sibling cloned at revision OLD only -- NEW was never fetched into it, the
## state the issue describes. NEW adds `newApi`, which `main.nim` calls; the
## pinned tree is an export of NEW, as the development shell's store copy is.
##
## No mocks: the compiler is the real one (`$NIM`, else `PATH`), the
## configuration file is the repository's own, the repositories are real git
## repositories, and the lint's judging step is the real script.

from repro_core/process_streams import drainStream
import std/[os, osproc, strtabs, strutils, tempfiles, unittest]

proc reproRoot(): string =
  ## The repository root, found upward from this source file: the tests run
  ## from several working directories.
  var dir = parentDir(currentSourcePath())
  while dir.len > 0 and dir != parentDir(dir):
    if fileExists(dir / "config.nims") and
        fileExists(dir / "apps" / "repro" / "repro.nim"):
      return dir
    dir = parentDir(dir)
  raise newException(IOError,
    "could not locate the repository root from " & currentSourcePath())

proc nimExe(): string =
  ## A missing compiler FAILS the suite below: this test is about what the
  ## compiler does with the configuration file.
  let fromEnv = getEnv("NIM")
  if fromEnv.len > 0 and fileExists(fromEnv):
    return fromEnv
  findExe("nim")

const ClearedVariables = [
  # The sibling policy's inputs: nothing the caller's shell set may decide.
  "REPRO_SIBLING_POLICY", "REPRO_SIBLING_PINNED", "REPRO_SIBLING_JUDGED",
  "REPRO_SIBLING_VERDICTS_OUT",
  # A git hook's repository-selecting variables (the suite may run inside
  # one): the fixture's git commands must address the fixture.
  "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
  "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX"]

proc runIn(dir: string; args: seq[string];
    env: openArray[(string, string)] = []): tuple[output: string, code: int] =
  ## Runs ``args`` in ``dir`` with the caller's environment minus
  ## `ClearedVariables`, plus ``env`` (an empty value removes a variable).
  var e = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ClearedVariables:
      e[k] = v
  e["GIT_AUTHOR_NAME"] = "fixture"
  e["GIT_AUTHOR_EMAIL"] = "fixture@example.invalid"
  e["GIT_COMMITTER_NAME"] = "fixture"
  e["GIT_COMMITTER_EMAIL"] = "fixture@example.invalid"
  for (k, v) in env:
    if v.len == 0:
      if e.hasKey(k): e.del(k)
    else:
      e[k] = v
  let p = startProcess(args[0], workingDir = dir, args = args[1 .. ^1],
    env = e, options = {poStdErrToStdOut, poUsePath})
  let output = drainStream(p.outputStream)
  let code = p.waitForExit()
  p.close()
  (output, code)

proc git(dir: string; args: varargs[string]): string =
  let r = runIn(dir, @["git"] & @args)
  doAssert r.code == 0, "git " & args.join(" ") & " in " & dir & ":\n" &
    r.output
  r.output.strip()

type Fixture = object
  root, consumer, sibling, pinnedTree: string
  oldRev, pinRev: string

proc makeUpstream(dir, module, oldDecl, newDecl: string):
    tuple[oldRev, newRev: string] =
  createDir(dir / "src")
  discard git(dir.parentDir, "init", "-q", dir)
  writeFile(dir / "src" / module, oldDecl & "\n")
  discard git(dir, "add", "-A")
  discard git(dir, "commit", "-qm", "old")
  result.oldRev = git(dir, "rev-parse", "HEAD")
  writeFile(dir / "src" / module, oldDecl & "\n" & newDecl & "\n")
  discard git(dir, "commit", "-qam", "new")
  result.newRev = git(dir, "rev-parse", "HEAD")

proc cloneAt(upstream, dest, rev: string) =
  ## A repository holding ``rev`` and its history only: a later revision of
  ## ``upstream`` is not an object in it.
  discard git(dest.parentDir, "init", "-q", dest)
  discard git(dest, "fetch", "-q", upstream, rev)
  discard git(dest, "checkout", "-q", rev)

proc makeFixture(siblingAtPin: bool): Fixture =
  let repo = reproRoot()
  result.root = createTempDir("repro-sibling-verdict-", "")
  let upstream = result.root / "upstream" / "nim-cli-spec"
  createDir(upstream.parentDir)
  let (oldRev, newRev) = makeUpstream(upstream, "clispec.nim",
    "proc oldApi*(): int = 1", "proc newApi*(): int = 2")
  result.oldRev = oldRev
  result.pinRev = newRev
  let ws = result.root / "ws"
  createDir(ws)
  result.sibling = ws / "nim-cli-spec"
  cloneAt(upstream, result.sibling, if siblingAtPin: newRev else: oldRev)
  result.pinnedTree = result.root / "pinned" / "nim-cli-spec"
  createDir(result.pinnedTree / "src")
  copyFile(upstream / "src" / "clispec.nim",
    result.pinnedTree / "src" / "clispec.nim")
  result.consumer = ws / "reprobuild"
  let policyDir = result.consumer / "libs" / "repro_core" / "src" / "repro_core"
  createDir(policyDir)
  createDir(result.consumer / "scripts" / "lib")
  copyFile(repo / "config.nims", result.consumer / "config.nims")
  copyFile(repo / "libs" / "repro_core" / "src" / "repro_core" /
    "sibling_source_policy.nim", policyDir / "sibling_source_policy.nim")
  copyFile(repo / "scripts" / "lib" / "sibling_verdicts.sh",
    result.consumer / "scripts" / "lib" / "sibling_verdicts.sh")
  writeFile(result.consumer / "repro.lock",
    "deps = [{ name = \"nim-cli-spec\", coord_kind = \"vcs\", url = " &
    "\"https://example.invalid/nim-cli-spec\", revision = \"" & newRev &
    "\", integrity = \"git-sha1:" & newRev & "\" }]\n")
  writeFile(result.consumer / "main.nim", "import clispec\necho newApi()\n")

proc nimIn(f: Fixture; nim: string; args: seq[string];
    env: openArray[(string, string)] = []): tuple[output: string, code: int] =
  runIn(f.consumer, @[nim] & args &
    @["--hints:off", "--nimcache:" & f.root / "nimcache-" & args[0],
      "main.nim"], env)

proc linesNaming(output, needle: string): seq[string] =
  for line in output.splitLines():
    if line.startsWith("config.nims:") and needle in line:
      result.add(line)

proc shortRev(rev: string): string = rev[0 ..< 12]

suite "nim check follows the sibling verdict of nim c":
  let nim = nimExe()

  test "the compiler this test needs is present":
    check nim.len > 0 and fileExists(nim)

  test "control: nim c takes the pinned tree and says the pin was never fetched":
    # Proves the fixture is the issue's: where git runs, the sibling is
    # judged stale and replaced. Without this, the cases below could pass on
    # a fixture whose sibling nothing considers stale.
    let f = makeFixture(siblingAtPin = false)
    defer: removeDir(f.root)
    check git(f.sibling, "cat-file", "-t", f.oldRev) == "commit"
    check runIn(f.sibling, @["git", "cat-file", "-e", f.pinRev]).code != 0
    let r = nimIn(f, nim, @["c", "-o:" & f.root / "main.bin"],
      {"CLI_SPEC_SRC": f.pinnedTree / "src"})
    check r.code == 0
    let said = linesNaming(r.output, "../nim-cli-spec/src")
    check said.len == 1
    if said.len == 1:
      check ("using $CLI_SPEC_SRC=" & f.pinnedTree / "src") in said[0]
      check shortRev(f.pinRev) in said[0]
      check "never fetched" in said[0]
    if r.code != 0: echo r.output

  test "a bare nim check names the sibling it could not judge":
    # THE REPRODUCTION. Unfixed, this compile failed on `undeclared
    # identifier` and no line named the sibling: config.nims observed
    # nothing and kept it in silence.
    let f = makeFixture(siblingAtPin = false)
    defer: removeDir(f.root)
    let r = nimIn(f, nim, @["check"], {"CLI_SPEC_SRC": f.pinnedTree / "src"})
    let said = linesNaming(r.output, "../nim-cli-spec/src")
    check said.len == 1
    if said.len == 1:
      check "without judging it" in said[0]
      check shortRev(f.oldRev) in said[0]
      check shortRev(f.pinRev) in said[0]
      check "check_nim_sources.sh" in said[0]
    if said.len != 1: echo r.output

  test "after the lint's judgement, nim check compiles the pinned tree":
    # The lint's sweep: judged once where git runs, then `nim check` follows
    # the verdict -- the tree `nim c` compiles -- and passes, with the report
    # printed once by the judgement and not repeated by the check.
    let f = makeFixture(siblingAtPin = false)
    defer: removeDir(f.root)
    let script = "set -euo pipefail\n" &
      "source scripts/lib/sibling_verdicts.sh\n" &
      "judge_config_siblings\n" &
      "printf 'PINNED=%s JUDGED=%s\\n' \"$REPRO_SIBLING_PINNED\" " &
      "\"$REPRO_SIBLING_JUDGED\"\n" &
      "exec \"$1\" check --hints:off --nimcache:\"$2\" main.nim\n"
    let r = runIn(f.consumer, @["bash", "-c", script, "judge", nim,
      f.root / "nimcache-judged"], {"CLI_SPEC_SRC": f.pinnedTree / "src"})
    check r.code == 0
    check "PINNED=CLI_SPEC_SRC JUDGED=1" in r.output
    let said = linesNaming(r.output, "../nim-cli-spec/src")
    check said.len == 1
    if said.len == 1:
      check "instead of the sibling" in said[0]
      check "never fetched" in said[0]
    check "undeclared identifier" notin r.output
    if r.code != 0 or said.len != 1: echo r.output

  test "with no pinned tree named, the judgement reports the stale sibling":
    let f = makeFixture(siblingAtPin = false)
    defer: removeDir(f.root)
    let script = "set -euo pipefail\n" &
      "source scripts/lib/sibling_verdicts.sh\n" &
      "judge_config_siblings\n" &
      "printf 'PINNED=[%s]\\n' \"$REPRO_SIBLING_PINNED\"\n"
    let r = runIn(f.consumer, @["bash", "-c", script],
      {"CLI_SPEC_SRC": ""})
    check r.code == 0
    check "PINNED=[]" in r.output
    let said = linesNaming(r.output, "../nim-cli-spec/src")
    check said.len == 1
    if said.len == 1:
      check "compiling against the sibling" in said[0]
      check "names no pinned tree" in said[0]
      check "never fetched" in said[0]
    if said.len != 1: echo r.output

  test "a sibling at the pin is compiled with no report":
    # Not noise: a bare `nim check` reads the sibling's HEAD from its files,
    # and a sibling at the pin needs no judgement.
    let f = makeFixture(siblingAtPin = true)
    defer: removeDir(f.root)
    let r = nimIn(f, nim, @["check"], {"CLI_SPEC_SRC": f.pinnedTree / "src"})
    check r.code == 0
    check linesNaming(r.output, "nim-cli-spec").len == 0
    if r.code != 0: echo r.output

  test "a stale nim-stackable-hooks sibling config.nims falls back to is said":
    # `$STACKABLE_HOOKS_SRC`-first, so it keeps that order; but when the
    # variable names nothing and the sibling is what config.nims falls to,
    # the sibling is judged as io-mon's is. Unfixed, it was compiled with no
    # word whatever its relation to the pin.
    let f = makeFixture(siblingAtPin = true)
    defer: removeDir(f.root)
    let upstream = f.root / "upstream" / "nim-stackable-hooks"
    let (oldRev, newRev) = makeUpstream(upstream, "stackable_hooks.nim",
      "proc oldHook*(): int = 1", "proc newHook*(): int = 2")
    cloneAt(upstream, f.consumer.parentDir / "nim-stackable-hooks", oldRev)
    writeFile(f.consumer / "repro.lock",
      readFile(f.consumer / "repro.lock").replace("}]\n",
        " }, { name = \"nim-stackable-hooks\", coord_kind = \"vcs\", " &
        "url = \"https://example.invalid/nim-stackable-hooks\", " &
        "revision = \"" & newRev & "\", integrity = \"\" }]\n"))
    let r = runIn(f.consumer, @[nim, "dump", "--hints:off",
      "./__probe__.nim"], {"STACKABLE_HOOKS_SRC": "",
        "CLI_SPEC_SRC": f.pinnedTree / "src"})
    check r.code == 0
    let said = linesNaming(r.output, "../nim-stackable-hooks/src")
    check said.len == 1
    if said.len == 1:
      check "compiling against the sibling" in said[0]
      check shortRev(newRev) in said[0]
      check "$STACKABLE_HOOKS_SRC names no pinned tree" in said[0]
    if said.len != 1: echo r.output
