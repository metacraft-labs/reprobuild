## test_cs_m6b_snippet_checked_at_compile_time: a configuration block written
## for a described tool is checked against the tool's description when the
## recipe compiles.
##
## The tool is cargo. Its `cli:` description declares the configuration-file
## keys its flags override (`build.target-dir`, `build.target`, `net.offline`,
## `term.color` with its closed set `auto|always|never`), so the package
## macro emits `cargoConfigDescription`, and a `tomlContent(ctx,
## cargoConfigDescription):` block is checked against it. A fixture writing an
## unknown key, and one writing a wrongly typed value, each fail to compile
## with an error naming the key at the line that wrote it; so does a literal
## outside the closed set and a section where a value belongs. The corrected
## fixture compiles: that is the vacuity guard, showing the failures come
## from the check and not from the fixture. A configuration value override
## (`configOverride(cargoConfigDescription, "net.offline", true)`, the
## `key=value` cargo's `--config` takes) is checked the same way.
##
## Each fixture is compiled out of process with `nim check` (the compiler's
## diagnostic is the assertion; `compiles(...)` cannot observe a `{.error.}`
## raised inside a macro's expansion), under the repository's `config.nims`,
## so it resolves the same libraries the build does. Nothing is mocked.

import std/[os, osproc, strutils, unittest]

proc repoRoot(): string =
  currentSourcePath().parentDir().parentDir().parentDir().parentDir()

type Probe = object
  ok: bool
  output: string

proc checkFixture(body, tag: string): Probe =
  ## Writes a recipe-side module importing cargo and the configuration
  ## writers, followed by `body`, and runs `nim check` on it.
  let scratch = repoRoot() / "build" /
    ("cs-m6b-compile-" & tag & "-" & $getCurrentProcessId())
  createDir(scratch)
  defer:
    try: removeDir(scratch)
    except CatchableError: discard
  let source = scratch / "fixture.nim"
  writeFile(source, "import repro_dsl_stdlib/configurables\n" &
    "import repro_dsl_stdlib/generated_config\n" &
    "import repro_dsl_stdlib/packages/cargo as cargo_module\n\n" &
    "let ctx = evalConfig:\n  discard\n\n" & body)
  let (output, code) = execCmdEx("nim check --hints:off --colors:off " &
    quoteShell(source), workingDir = repoRoot())
  Probe(ok: code == 0, output: output)

proc snippet(lines: varargs[string]): string =
  ## A `tomlContent` block for cargo with `lines` as its body (indented by
  ## the caller). The block starts on line 8 of the fixture, so its first
  ## body line is line 9.
  result = "let rendered = tomlContent(ctx, " &
    "cargo_module.cargoConfigDescription):\n"
  for line in lines:
    result.add("  " & line & "\n")
  result.add("echo renderToString(rendered)\n")

const corrected = [
  "build:",
  "  `target-dir` = \"out/target\"",
  "  target = \"x86_64-unknown-linux-gnu\"",
  "net:",
  "  offline = true",
  "term:",
  "  color = \"never\""]

proc errorLine(p: Probe): string =
  for line in p.output.splitLines:
    if "Error:" in line:
      return line
  ""

suite "test_cs_m6b_snippet_checked_at_compile_time":

  test "the corrected fixture compiles (vacuity guard)":
    let p = checkFixture(snippet(corrected), "corrected")
    if not p.ok:
      echo p.output
    check p.ok

  test "an unknown key fails to compile, naming the key and its line":
    var lines = @corrected
    lines.insert("  jobs = 4", 1)
    let p = checkFixture(snippet(lines), "unknown")
    check not p.ok
    let e = errorLine(p)
    check "fixture.nim(10," in e
    check "tomlContent: configuration of 'cargo': unknown key 'build.jobs'" in e

  test "a wrongly typed value fails to compile, naming the key":
    var lines = @corrected
    lines[4] = "  offline = \"yes\""
    let p = checkFixture(snippet(lines), "wrong-type")
    check not p.ok
    let e = errorLine(p)
    check "fixture.nim(13," in e
    check "key 'net.offline' has the string \"yes\"; expected true or " &
      "false" in e

  test "a literal outside the closed set fails to compile":
    var lines = @corrected
    lines[6] = "  color = \"sometimes\""
    let p = checkFixture(snippet(lines), "closed-set")
    check not p.ok
    let e = errorLine(p)
    check "fixture.nim(15," in e
    check "key 'term.color' has the string \"sometimes\"; expected one " &
      "of: auto, always, never" in e

  test "a key spelt in another convention is unknown, with the right one":
    var lines = @corrected
    lines[1] = "  target_dir = \"out/target\""
    let p = checkFixture(snippet(lines), "convention")
    check not p.ok
    check "unknown key 'build.target_dir' (did you mean " &
      "'build.target-dir'?)" in errorLine(p)

  test "a section where a value belongs fails to compile":
    var lines = @corrected
    lines[4] = "  offline:"
    lines.insert("    enabled = true", 5)
    let p = checkFixture(snippet(lines), "section")
    check not p.ok
    check "key 'net.offline' has a table; expected true or false" in
      errorLine(p)

  test "a configuration value override is checked the same way":
    let good = checkFixture("echo configOverride(" &
      "cargo_module.cargoConfigDescription, \"term.color\", \"never\")\n",
      "override-good")
    if not good.ok:
      echo good.output
    check good.ok
    let unknown = checkFixture("echo configOverride(" &
      "cargo_module.cargoConfigDescription, \"build.jobs\", 4)\n",
      "override-unknown")
    check not unknown.ok
    check "fixture.nim(8," in errorLine(unknown)
    check "configOverride: configuration of 'cargo': unknown key " &
      "'build.jobs'" in errorLine(unknown)
    let wrong = checkFixture("echo configOverride(" &
      "cargo_module.cargoConfigDescription, \"net.offline\", \"yes\")\n",
      "override-wrong")
    check not wrong.ok
    check "key 'net.offline' has the string \"yes\"; expected true or " &
      "false" in errorLine(wrong)
