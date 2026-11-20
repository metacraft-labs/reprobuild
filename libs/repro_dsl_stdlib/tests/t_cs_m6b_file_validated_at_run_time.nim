## test_cs_m6b_file_validated_at_run_time: configuration a writer produces
## for a described tool is validated at run time against the tool's
## description.
##
## The tool is cargo, whose `cli:` description declares the configuration
## keys its flags override (see `t_cs_m6b_snippet_checked_at_compile_time`).
## The run-time validator reads `cargoConfigDescription`, the table the
## package macro derived once, and:
##
## * accepts a valid whole `.cargo/config.toml` and rejects an unknown key, a
##   value of the wrong type and a value outside a closed set, each message
##   naming the file, the line and the key; a key spelt in another convention
##   than cargo's (kebab-case, as the description declares) is unknown, with
##   cargo's spelling suggested;
## * checks the tree a `tomlContent` block built, which is where a value the
##   compiler cannot see is caught: a configurable whose resolved value lies
##   outside the closed set;
## * checks a tree built by code before `fs.writeStructured` writes it, and
##   writes nothing when it does not fit.
##
## Real TOML text parsed by confutils' TOML adapter, real configurables and a
## real local store under a temporary home; nothing is mocked.

import std/[os, strutils, unittest]

from clispec/model import cnKebabCase
import repro_local_store
import repro_dsl_stdlib/configurables
import repro_dsl_stdlib/generated_config
import repro_dsl_stdlib/packages/cargo as cargo_module

const description = cargo_module.cargoConfigDescription

const validFile = """
[build]
target-dir = "out/target"
target = "x86_64-unknown-linux-gnu"

[net]
offline = true

[term]
color = "never"
"""

proc issuesOf(text: string): seq[CliConfigIssue] =
  configTextIssues(description, ".cargo/config.toml", text, cfToml)

proc messageOf(text: string): string =
  try:
    checkConfigText(description, ".cargo/config.toml", text)
  except ConfigValidationError as e:
    return e.msg
  ""

suite "test_cs_m6b_file_validated_at_run_time":

  test "the description holds cargo's declared keys, kebab-case":
    check description.program == "cargo"
    check description.convention == cnKebabCase
    check description.cliConfigTableKeys == @["build.target",
      "build.target-dir", "net.offline", "term.color"]

  test "a valid whole file is accepted":
    check issuesOf(validFile).len == 0
    check messageOf(validFile) == ""

  test "an unknown key names the file, the line and the key":
    let text = validFile.replace("[net]\n", "[net]\nretry = 3\n")
    let issues = issuesOf(text)
    check issues.len == 1
    check issues[0].kind == cikUnknownKey
    check issues[0].key == "net.retry"
    check issues[0].line == 6
    check ".cargo/config.toml:6: unknown key 'net.retry'" in messageOf(text)

  test "a value of the wrong type names the file, the line and the key":
    let text = validFile.replace("offline = true", "offline = \"yes\"")
    let msg = messageOf(text)
    check ".cargo/config.toml:6: key 'net.offline' has the string " &
      "\"yes\"; expected true or false" in msg
    check "configuration of 'cargo'" in msg

  test "a value outside the closed set names the file, the line and the key":
    let text = validFile.replace("color = \"never\"", "color = \"sometimes\"")
    let issues = issuesOf(text)
    check issues.len == 1
    check issues[0].kind == cikNotAllowed
    check ".cargo/config.toml:9: key 'term.color' has the string " &
      "\"sometimes\"; expected one of: auto, always, never" in messageOf(text)

  test "a key in another naming convention is unknown, cargo's suggested":
    let text = validFile.replace("target-dir", "target_dir")
    check ".cargo/config.toml:2: unknown key 'build.target_dir' (did you " &
      "mean 'build.target-dir'?)" in messageOf(text)

  test "every issue of a file is reported, in file order":
    let text = validFile.replace("[net]\n", "[net]\nretry = 3\n").replace(
      "color = \"never\"", "color = 1")
    let issues = issuesOf(text)
    check issues.len == 2
    check issues[0].line == 6
    check issues[1].line == 10

  test "a block's tree is checked at run time: a configurable's value":
    let ctx = evalConfig:
      let color = configurable "never"
      color.override "sometimes"
    # The first configurable the context constructed (as the smoke test of
    # the block macros reads one).
    let colorHandle = Configurable[string](id: ConstructionId(0))
    expect ConfigValidationError:
      discard tomlContent(ctx, description):
        term:
          color = colorHandle
    try:
      discard tomlContent(ctx, description):
        term:
          color = colorHandle
    except ConfigValidationError as e:
      check e.program == "cargo"
      check e.issues.len == 1
      check "key 'term.color' has the string \"sometimes\"" in e.msg
      check "tomlContent block at" in e.msg

  test "a block that fits renders as before":
    let ctx = evalConfig:
      discard
    let rendered = tomlContent(ctx, description):
      net:
        offline = true
    check "offline = true" in renderToString(rendered)

  test "fs.writeStructured checks a tree built by code and writes nothing":
    let home = getTempDir() / ("cs-m6b-home-" & $getCurrentProcessId())
    createDir(home)
    defer: removeDir(home)
    putEnv("REPRO_HOME_PROFILE_TARGET", home)
    defer: delEnv("REPRO_HOME_PROFILE_TARGET")
    let scope = resolveHomeScope()
    var store = openStore(home / "store")
    var state = newApplyState()
    let term = svObject()
    term.setField("colour", svString("never"))
    let root = svObject()
    root.setField("term", term)
    try:
      discard writeStructured(state, store, scope, "~/.cargo/config.toml",
        cfToml, root, description = description)
      check false
    except ConfigValidationError as e:
      check "~/.cargo/config.toml: unknown key 'term.colour'" in e.msg
    check not fileExists(home / ".cargo" / "config.toml")
    let fixed = svObject()
    fixed.setField("color", svString("never"))
    root.setField("term", fixed)
    let applied = writeStructured(state, store, scope, "~/.cargo/config.toml",
      cfToml, root, description = description)
    check applied.outcome == oaCreated
    check "color = \"never\"" in readFile(home / ".cargo" / "config.toml")

  test "a whole file given as text is validated before it is written":
    let home = getTempDir() / ("cs-m6b-text-" & $getCurrentProcessId())
    createDir(home)
    defer: removeDir(home)
    putEnv("REPRO_HOME_PROFILE_TARGET", home)
    defer: delEnv("REPRO_HOME_PROFILE_TARGET")
    let scope = resolveHomeScope()
    var store = openStore(home / "store")
    var state = newApplyState()
    let bad = validFile.replace("offline = true", "offline = 1")
    try:
      discard configFileText(state, store, scope, "~/.cargo/config.toml", bad,
        description)
      check false
    except ConfigValidationError as e:
      check "~/.cargo/config.toml:6: key 'net.offline' has an integer 1; " &
        "expected true or false" in e.msg
    check not fileExists(home / ".cargo" / "config.toml")
    let applied = configFileText(state, store, scope, "~/.cargo/config.toml",
      validFile, description)
    check applied.outcome == oaCreated
    check readFile(home / ".cargo" / "config.toml") == validFile

  test "a configuration value override is checked at run time":
    check configOverride(description, "net.offline", true) ==
      "net.offline=true"
    check configOverride(description, "build.target-dir", "a \"b\"") ==
      "build.target-dir=\"a \\\"b\\\"\""
    var chosen = "sometimes"
    try:
      discard configOverride(description, "term.color", chosen)
      check false
    except ConfigValidationError as e:
      check "configuration override: key 'term.color' has the string " &
        "\"sometimes\"; expected one of: auto, always, never" in e.msg
    chosen = "auto"
    check configOverride(description, "term.color", chosen) ==
      "term.color=\"auto\""
