## Smoke test for the M60 home profile intent layer. Verifies the
## parser, predicate normalizer, structural editor, and effective-
## config resolver compile and produce the expected behavior on a
## handful of small fixtures. The real M60 gates live under
## `tests/e2e/home-intent/`.

import std/[options, os, sets, strutils, tables, unittest]
from repro_core/paths import extendedPath

import repro_home_intent

const SamplePath = "/tmp/repro-home-smoke-profile.nim"

const SampleProfile = """
import repro/profile

profile "zahary":
  activity default:
    neovim
    tmux
    when windows:
      windows-terminal

  activity develop_software:
    git
    gh

  config:
    git:
      userName = "Zahary"

  hosts:
    "dev-laptop": [develop_software]
"""

proc writeSample(path = SamplePath): string =
  writeFile(extendedPath(path), SampleProfile)
  result = path

suite "Home-intent smoke":

  test "parse recognized profile shape":
    let path = writeSample()
    let prof = loadProfile(path)
    check prof.root.kind == nkProfileRoot
    check prof.root.name == "zahary"
    check prof.root.children.len == 4
    let act = findActivity(prof, "default")
    check act.isSome
    check act.get.activityChildren.len == 3  # neovim, tmux, when block

  test "rejects unrecognized top-level form":
    let bad = """
import repro/profile

profile "x":
  activity default:
    neovim

  packages:
    - extra
"""
    let badPath = "/tmp/repro-home-smoke-bad-toplevel.nim"
    writeFile(extendedPath(badPath), bad)
    expect EUnstructured:
      discard loadProfile(badPath)
    removeFile(extendedPath(badPath))

  test "rejects runtime control flow inside activity body":
    let bad = """
import repro/profile

profile "x":
  activity default:
    for pkg in @["a", "b"]:
      pkg
"""
    let badPath = "/tmp/repro-home-smoke-bad-for.nim"
    writeFile(extendedPath(badPath), bad)
    expect EUnstructured:
      discard loadProfile(badPath)
    removeFile(extendedPath(badPath))

  test "predicate canonicalize: commutative ordering":
    check canonicalize("windows and arm64") == "arm64 and windows"
    check canonicalize("arm64 and windows") == "arm64 and windows"
    check canonicalize("WINDOWS and ARM64") == "arm64 and windows"
    check canonicalize("(windows) and (arm64)") == "arm64 and windows"

  test "predicate canonicalize: nested or/and":
    check canonicalize("a or b or c") ==
          canonicalize("c or b or a")
    check canonicalize("not (windows or macos)") ==
          "not (macos or windows)"

  test "predicate evaluates host facts":
    let ctx = HostContext(platform: "windows", arch: "arm64",
      host: "dev-laptop")
    let ast = parsePredicate("", "windows and arm64", 0)
    check evaluateBool(ast, ctx)
    check not evaluateBool(parsePredicate("", "macos", 0), ctx)
    check evaluateBool(parsePredicate("", "host == \"dev-laptop\"", 0), ctx)
    check evaluateBool(
      parsePredicate("", "host in [\"a\", \"dev-laptop\"]", 0), ctx)

  test "round-trip: add then remove restores byte-equal file":
    let path = writeSample()
    let original = readFile(extendedPath(path))
    addPackageReference(path, "ripgrep", activity = "default")
    let added = readFile(extendedPath(path))
    check added != original
    check "ripgrep" in added
    removePackageReference(path, "ripgrep", activity = "default")
    let after = readFile(extendedPath(path))
    check after == original
    removeFile(extendedPath(path))

  test "setConfigurable creates config + sub-block + entry":
    # Use a profile WITHOUT a config block.
    let p = """
import repro/profile

profile "x":
  activity default:
    neovim
"""
    let path = "/tmp/repro-home-smoke-set-config.nim"
    writeFile(extendedPath(path), p)
    setConfigurable(path, "git.userName", "Zahary", nil)
    setConfigurable(path, "git.userEmail", "z@example.com", nil)
    let after = readFile(extendedPath(path))
    check "config:" in after
    check "git:" in after
    check "userName = \"Zahary\"" in after
    check "userEmail = \"z@example.com\"" in after
    # The git: header must appear before either entry.
    let gitHeader = after.find("git:")
    let nameLine = after.find("userName")
    let emailLine = after.find("userEmail")
    check gitHeader >= 0
    check gitHeader < nameLine
    check nameLine < emailLine
    removeFile(extendedPath(path))

  # ---------------------------------------------------------------------
  # M82 home-scope follow-up: `depends_on` shape validation.
  #
  # The parser must reject malformed `depends_on = [...]` entries on the
  # resource attribute with `EUnstructured` naming the offending text.
  # The parser does NOT validate the KIND TAG against a closed set —
  # only the SHAPE (list literal of `"kind:name"` strings with non-empty
  # halves around the first `:`). The planner catches a typo'd kind
  # downstream when no resource satisfies the `(kind, name)` pair.
  # ---------------------------------------------------------------------

  test "depends_on shape validation: rejects non-list RHS":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "\"fs.managedBlock:other\"",
          resourceAttrLine: 7))
    except EUnstructured as e:
      caught = true
      check "list literal" in e.expected
      check e.line == 7
    check caught

  test "depends_on shape validation: rejects empty entry":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"fs.managedBlock:a\", \"\"]",
          resourceAttrLine: 11))
    except EUnstructured as e:
      caught = true
      check "non-empty 'kind:name'" in e.expected
      check e.line == 11
    check caught

  test "depends_on shape validation: rejects no-colon entry":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"no-colon-here\"]",
          resourceAttrLine: 4))
    except EUnstructured as e:
      caught = true
      check "':' separator" in e.expected
    check caught

  test "depends_on shape validation: rejects empty kind half":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\":someName\"]",
          resourceAttrLine: 3))
    except EUnstructured as e:
      caught = true
      check "non-empty kind" in e.expected
    check caught

  test "depends_on shape validation: rejects empty name half":
    var caught = false
    try:
      discard parseDependsOnAttr("/tmp/x.nim",
        IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
        IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
          resourceAttrValueSource: "[\"fs.managedBlock:\"]",
          resourceAttrLine: 2))
    except EUnstructured as e:
      caught = true
      check "non-empty name" in e.expected
    check caught

  test "depends_on shape validation: accepts a well-formed list":
    # A well-formed list with two entries; first-colon-split keeps the
    # full name half even when it contains further colons (e.g. a
    # resource address with a `:` in it, or a registry key path).
    let parsed = parseDependsOnAttr("/tmp/x.nim",
      IntentNode(kind: nkResourceEntry, resourceAddress: "shellRc"),
      IntentNode(kind: nkResourceAttr, resourceAttrKey: "depends_on",
        resourceAttrValueSource:
          "[\"fs.managedBlock:bashrc\", \"env.userVariable:editor:nvim\"]",
        resourceAttrLine: 9))
    check parsed.len == 2
    check parsed[0].kind == "fs.managedBlock"
    check parsed[0].name == "bashrc"
    check parsed[1].kind == "env.userVariable"
    check parsed[1].name == "editor:nvim"   # first-colon-split

  test "effective config buckets enabled vs inert overrides":
    let path = writeSample()
    let prof = loadProfile(path)
    let ctxLaptop = HostContext(platform: "linux", arch: "x86_64",
      host: "dev-laptop")
    let cfg = resolveEffectiveConfig(prof, "dev-laptop", ctxLaptop)
    check "neovim" in cfg.enabledPackages
    check "tmux" in cfg.enabledPackages
    check "git" in cfg.enabledPackages          # via develop_software
    check "windows-terminal" notin cfg.enabledPackages  # gated by `windows`
    check "git" in cfg.overrides
    check "userName" in cfg.overrides["git"]
    check cfg.inertOverrides.len == 0
    removeFile(extendedPath(path))
