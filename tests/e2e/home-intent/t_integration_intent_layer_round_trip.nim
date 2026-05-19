## M60 gate: `integration_intent_layer_round_trip`.
##
## Normative description (from `Reprobuild-Development.milestones.org`):
##
##   Add + remove the same package; file is byte-identical. Add a
##   package to a profile with no `activity default:` block; the
##   activity is created and the package appears as its first child
##   with correct indentation. Add a package under
##   `--when "windows and arm64"`; the `when windows and arm64:` block
##   is created (with normalized predicate ordering) if absent and
##   appended if present. Two predicate spellings that normalize to
##   the same form land in the same `when` block. Comments adjacent
##   to edited lines survive. `EUnstructured` fires for a profile
##   where an activity body is built by a runtime loop.
##
## The gate drives the production `repro_home_intent` library through
## its public API surface (no internal helpers, no mocks of the parser
## or editor). Fixture profile sources are the only "mock" — they are
## real `home.nim` files committed under `tests/fixtures/home-intent/`.

import std/[os, strutils, unittest]

import repro_home_intent

const FixtureRoot = currentSourcePath().parentDir().parentDir().parentDir() /
  "fixtures" / "home-intent"

proc tmpDir(name: string): string =
  result = getTempDir() / "repro-home-intent-rt" / name
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc copyFixture(name, intoDir: string): string =
  result = intoDir / "home.nim"
  let src = FixtureRoot / name
  doAssert fileExists(src), "missing fixture: " & src
  copyFile(src, result)

suite "M60 round-trip gate":

  test "add then remove yields byte-identical file":
    let dir = tmpDir("rt-byte-equal")
    let path = copyFixture("with_default.nim", dir)
    let original = readFile(path)
    addPackageReference(path, "ripgrep", activity = "default")
    let added = readFile(path)
    check added != original
    check "    ripgrep" in added
    removePackageReference(path, "ripgrep", activity = "default")
    let after = readFile(path)
    check after == original

  test "adds package to profile without `activity default:` and indents correctly":
    let dir = tmpDir("rt-create-default")
    let path = copyFixture("without_default.nim", dir)
    addPackageReference(path, "neovim", activity = "default")
    let body = readFile(path)
    # The `activity default:` block must exist now.
    check "activity default:" in body
    # `neovim` must appear AS THE FIRST CHILD of the new activity,
    # at indent 4 (childIndent = root indent 0 + step 2 + step 2).
    let actIdx = body.find("  activity default:")
    check actIdx >= 0
    let neoIdx = body.find("    neovim", actIdx)
    check neoIdx > actIdx
    # No content between the header and `neovim` other than the
    # newline separating them.
    let between = body[actIdx ..< neoIdx]
    let lastNl = between.rfind("\n")
    check lastNl >= 0
    # Everything between the header's newline and `    neovim`
    # is whitespace-only (no other package, comment, etc.).
    let head = "  activity default:"
    check between.startsWith(head)
    let interior = between[head.len .. ^1]
    for c in interior:
      check c in {' ', '\t', '\r', '\n'}

  test "adding under `--when windows and arm64` creates a normalized block":
    let dir = tmpDir("rt-when-create")
    let path = copyFixture("with_default.nim", dir)
    addPackageReference(path, "raspi-tools", activity = "default",
                        predicate = "windows and arm64")
    let body = readFile(path)
    # The canonical form sorts operands lexicographically, so the
    # header line MUST be `when arm64 and windows:` (not `windows
    # and arm64`).
    check "    when arm64 and windows:" in body
    check "    when windows and arm64:" notin body
    # `raspi-tools` is inside the new block at the body indent (6).
    let blkIdx = body.find("    when arm64 and windows:")
    check blkIdx >= 0
    let pkgIdx = body.find("      raspi-tools", blkIdx)
    check pkgIdx > blkIdx

  test "two predicate spellings land in the same `when` block":
    let dir = tmpDir("rt-when-same")
    let path = copyFixture("with_default.nim", dir)
    addPackageReference(path, "pkg-a", activity = "default",
                        predicate = "windows and arm64")
    addPackageReference(path, "pkg-b", activity = "default",
                        predicate = "arm64 and windows")
    let body = readFile(path)
    # Exactly one `when arm64 and windows:` block must exist.
    let blkCount = body.count("when arm64 and windows:")
    check blkCount == 1
    check body.count("when windows and arm64:") == 0
    # Both packages are present inside the same block.
    check "      pkg-a" in body
    check "      pkg-b" in body
    let blkIdx = body.find("when arm64 and windows:")
    let aIdx = body.find("      pkg-a", blkIdx)
    let bIdx = body.find("      pkg-b", blkIdx)
    check aIdx > blkIdx
    check bIdx > blkIdx

  test "appends to existing when block (keyword preserved) regardless of flag":
    # The fixture uses `when arm64 and windows:` already. Adding with
    # `--if "windows and arm64"` must find the existing block (since
    # both predicates normalize identically) and append in-place WITHOUT
    # creating an `if` block.
    let dir = tmpDir("rt-when-keyword-keep")
    let path = copyFixture("with_when_block.nim", dir)
    addPackageReference(path, "extra-tools", activity = "default",
                        predicate = "windows and arm64",
                        predicateKeyword = ckIf)
    let body = readFile(path)
    check "when arm64 and windows:" in body
    check "if arm64 and windows:" notin body
    check "      raspi-tools" in body
    check "      extra-tools" in body

  test "comments adjacent to the edited line survive byte-identical removal":
    let dir = tmpDir("rt-comments")
    let path = copyFixture("with_comments.nim", dir)
    let original = readFile(path)
    # Both comments around the editable region must be preserved
    # through the add+remove round-trip.
    addPackageReference(path, "ripgrep", activity = "default")
    let added = readFile(path)
    # Comments still present after the add.
    check "    # editors I rely on everywhere" in added
    check "    # multiplexer for tmate/tmux+SSH sessions" in added
    removePackageReference(path, "ripgrep", activity = "default")
    let after = readFile(path)
    check after == original

  test "EUnstructured fires for a `for` loop building an activity body":
    let dir = tmpDir("rt-eunstructured")
    let path = copyFixture("runtime_loop.nim", dir)
    var raisedKind = ""
    var raisedLine = -1
    try:
      addPackageReference(path, "ripgrep", activity = "default")
    except EUnstructured as e:
      raisedKind = "EUnstructured"
      raisedLine = e.line
    check raisedKind == "EUnstructured"
    # The `for` line is line 5 in the fixture (1-based).
    check raisedLine == 5
