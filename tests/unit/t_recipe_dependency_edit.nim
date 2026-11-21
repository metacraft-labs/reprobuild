## The text edits `repro add` and `repro remove` make to the dependency
## sections of a `repro.nim` (`repro_cli_support/recipe_dependency_edit`), and
## the offline comparison of the edited recipe with `repro.lock` they report,
## as pure functions over texts.
##
## WHY a unit test beside the integration case
## (`t_repro_add_package_vs_ws_add_repo`): that case drives the real binary
## over one recipe shape. The shapes that decide whether an edit lands in the
## right place, or corrupts the file, are exercised here against exact bytes:
## CRLF and unterminated files, comments (including ones that contain `"""`),
## multi-line string literals and block comments, entries under `when` / `if`
## / `case`, sections written inline, names that share a prefix, and files
## declaring several packages.
##
## Test-double policy: none. The functions under test take and return text;
## every input is a literal recipe or lock in the shape authors and
## `repro lock refresh` write.

import std/[strutils, unittest]

import repro_cli_support/recipe_dependency_edit

proc added(source, section, entry: string; package = "hello"): string =
  let e = addDependency(source, package, section, entry)
  checkpoint(e.diagnostic)
  check e.status == desChanged
  e.text

proc removed(source, selector: string; package = "hello"): string =
  let e = removeDependency(source, package, selector)
  checkpoint(e.diagnostic)
  check e.status == desChanged
  e.text

proc roundTrips(source, section, entry: string; package = "hello") =
  ## Adding ``entry`` and removing it again restores ``source`` byte for byte.
  let a = added(source, section, entry, package)
  check a != source
  check removed(a, entry.splitWhitespace()[0], package) == source

const basic = """import reprobuild

package hello:
  ## The program.
  uses:
    "nim >=2.2 <3.0"

  executable hello:
    discard
"""

const conditional = """package hello:
  uses:
    "nim"
    when defined(macosx):
      "clang"
    else: "gcc >=12"
    if useZstd:
      "zstd"
    case flavour
    of "full": "curl"
    else: discard
    policyName:
      "openssl"
  when defined(windows):
    runtimeDeps:
      "vcruntime"
  executable hello:
    discard
"""

const prefixed = """package hello:
  uses:
    "openssl3"
    "openssl-dev >=1"
"""

const two = """import reprobuild

package a:
  uses:
    "nim"

package `b-c`:
  executable b:
    discard
"""

proc lock(packages: openArray[(string, string)];
          unselected: openArray[string] = []): string =
  var items: seq[string]
  for (name, version) in packages:
    items.add("{ name = \"" & name & "\", version = \"" & version &
      "\", source = \"" & name & "\", selection = \"" &
      (if name in unselected: "unselected" else: "selected") & "\" }")
  "schema = \"reprobuild.solved-graph-lock.v3\"\n\n[lock]\n" &
    "platform = \"amd64-linux\"\noptimal = false\n" &
    "inputs_digest = \"fixture\"\nvariants = []\n" &
    "packages = [" & items.join(", ") & "]\ndeps = []\n"

proc editedRecipe(): string = added(basic, "uses", "zlib >=1.3")

suite "line endings":

  test "a CRLF file keeps CRLF on every line, and the round trip is exact":
    let crlf = basic.replace("\n", "\r\n")
    let a = added(crlf, "uses", "zlib")
    check a == crlf.replace("    \"nim >=2.2 <3.0\"\r\n",
      "    \"nim >=2.2 <3.0\"\r\n    \"zlib\"\r\n")
    check removed(a, "zlib") == crlf
    let b = added(crlf, "buildDeps", "openssl >=3.3 <4.0")
    check b == crlf.replace("  ## The program.\r\n",
      "  ## The program.\r\n  buildDeps:\r\n    \"openssl >=3.3 <4.0\"\r\n")
    check removed(b, "openssl") == crlf

  test "an unterminated last line stays unterminated, both ways":
    let src = "package hello:\n  uses:\n    \"nim\""
    let a = added(src, "uses", "zlib")
    check a == "package hello:\n  uses:\n    \"nim\"\n    \"zlib\""
    check removed(a, "zlib") == src
    let crlf = "package hello:\r\n  uses:\r\n    \"nim\""
    let b = added(crlf, "uses", "zlib")
    check b == "package hello:\r\n  uses:\r\n    \"nim\"\r\n    \"zlib\""
    check removed(b, "zlib") == crlf

suite "comments":

  test "comments inside and around the section stay where they are":
    let src = """package hello:
  # The libraries.
  uses:   # what it links
    # the compiler
    "nim"   # pinned below
    # zlib for the archive reader
    "zlib >=1.3"  # see notes
    # a trailing comment of the section

  executable hello:
    discard
"""
    let a = added(src, "uses", "curl")
    check a == src.replace("    \"zlib >=1.3\"  # see notes\n",
      "    \"zlib >=1.3\"  # see notes\n    \"curl\"\n")
    check removed(a, "curl") == src
    # The comment above an entry is the author's; removing the entry leaves
    # it (only the section's own header goes with its last entry).
    check removed(src, "zlib") == src.replace(
      "    \"zlib >=1.3\"  # see notes\n", "")
    roundTrips(src, "runtimeDeps", "bash")

  test "a comment containing an odd number of triple quotes flips nothing":
    let src = "package hello:\n" &
      "  # a doc example: \"\"\"\n" &
      "  uses:\n" &
      "    \"nim\" # closes \"\"\" in a comment\n" &
      "  #[ a block comment with \"\"\" inside ]#\n" &
      "  executable hello:\n" &
      "    discard\n"
    let a = added(src, "uses", "zlib")
    check a == src.replace("    \"nim\" # closes \"\"\" in a comment\n",
      "    \"nim\" # closes \"\"\" in a comment\n    \"zlib\"\n")
    check removed(a, "zlib") == src
    check removed(src, "nim") == src.replace(
      "  uses:\n    \"nim\" # closes \"\"\" in a comment\n", "")

  test "a new section goes after the doc comment, before a statement's own":
    let src = """package hello:
  ## The program.

  # The entry point; keep it first.
  # (two lines of comment)
  executable hello:
    discard
"""
    let a = added(src, "uses", "zlib")
    check a == src.replace("  # The entry point",
      "  uses:\n    \"zlib\"\n  # The entry point")
    check removed(a, "zlib") == src
    # A block comment directly above the statement belongs to it too.
    let blk = "package hello:\n  #[ the\n  entry point ]#\n" &
      "  executable hello:\n    discard\n"
    check added(blk, "uses", "zlib") == "package hello:\n  uses:\n" &
      "    \"zlib\"\n  #[ the\n  entry point ]#\n" &
      "  executable hello:\n    discard\n"
    # A `##` doc block stays above the new section.
    let doc = "package hello:\n  ##[ the\n  package ]##\n" &
      "  executable hello:\n    discard\n"
    check added(doc, "uses", "zlib") == "package hello:\n  ##[ the\n" &
      "  package ]##\n  uses:\n    \"zlib\"\n  executable hello:\n" &
      "    discard\n"

suite "multi-line literals and comments":

  test "an entry never lands inside a section's trailing triple-quoted string":
    let src = "package hello:\n" &
      "  uses:\n" &
      "    \"nim\"\n" &
      "    description(\"\"\"\n" &
      "    multi\n" &
      "    \"\"\")\n" &
      "  executable hello:\n" &
      "    discard\n"
    let a = added(src, "uses", "zlib")
    check a == src.replace("    \"\"\")\n", "    \"\"\")\n    \"zlib\"\n")
    check removed(a, "zlib") == src

  test "a literal's continuation lines are never statements":
    # The string's lines sit at the body's indentation and look like a
    # section and a package; the section's real end is the closing quotes.
    let src = "package hello:\n" &
      "  uses:\n" &
      "    \"nim\"\n" &
      "    script(\"\"\"\n" &
      "  uses:\n" &
      "    \"zlib\"\n" &
      "package other:\n" &
      "\"\"\")\n" &
      "  executable hello:\n" &
      "    discard\n"
    check packageNamesOf(src) == @["hello"]
    let r = removeDependency(src, "hello", "zlib")
    check r.status == desNotFound
    check r.text == src
    let a = added(src, "uses", "zlib")
    check a == src.replace("\"\"\")\n", "\"\"\")\n    \"zlib\"\n")
    check removed(a, "zlib") == src

  test "an entry followed by a block comment spanning lines":
    let src = "package hello:\n" &
      "  uses:\n" &
      "    \"nim\" #[ the compiler,\n" &
      "    \"zlib\" is not here ]#\n" &
      "  executable hello:\n" &
      "    discard\n"
    let r = removeDependency(src, "hello", "zlib")
    check r.status == desNotFound
    let a = added(src, "uses", "zlib")
    check a == src.replace("    \"zlib\" is not here ]#\n",
      "    \"zlib\" is not here ]#\n    \"zlib\"\n")
    check removed(a, "zlib") == src
    # Removing the entry takes the comment it opens with it.
    check removed(src, "nim") == "package hello:\n  executable hello:\n" &
      "    discard\n"

  test "raw strings, character literals and quotes in strings":
    let src = "package hello:\n" &
      "  let sep = '\"'\n" &
      "  let hash = '#'\n" &
      "  let path = r\"C:\\dir\\\"\n" &
      "  let q = \"a \\\"#\\\" b\"\n" &
      "  uses:\n" &
      "    r\"nim\"\n" &
      "  executable hello:\n" &
      "    discard\n"
    let a = added(src, "uses", "zlib")
    check a == src.replace("    r\"nim\"\n", "    r\"nim\"\n    \"zlib\"\n")
    check removed(a, "zlib") == src
    check addDependency(src, "hello", "uses", "nim").status == desUnchanged
    check removed(src, "nim") == src.replace("  uses:\n    r\"nim\"\n", "")

suite "conditional and nested entries are never touched":


  test "remove of an entry only under a condition is refused, naming its line":
    for (name, line) in [("clang", "5"), ("gcc", "6"), ("zstd", "8"),
                         ("curl", "10"), ("openssl", "13"),
                         ("vcruntime", "16")]:
      let r = removeDependency(conditional, "hello", name)
      checkpoint(name & ": " & r.diagnostic)
      check r.status == desRefused
      check r.text == conditional
      check "only under a condition or a nested call" in r.diagnostic
      check ("line " & line) in r.diagnostic

  test "a conditional entry is not counted as present; add writes one":
    let a = added(conditional, "uses", "clang")
    check a == conditional.replace("      \"openssl\"\n",
      "      \"openssl\"\n    \"clang\"\n")
    # Removing the unconditional one leaves the conditional one alone.
    check removed(a, "clang") == conditional
    roundTrips(conditional, "uses", "zlib")
    roundTrips(conditional, "runtimeDeps", "bash")

suite "sections written inline":

  test "one-line sections are not extended":
    for src in ["package hello:\n  uses: \"nim\"\n",
                "package hello:\n  uses: [\"nim\", \"zlib\"]\n",
                "package hello:\n  uses: [\n    \"nim\",\n    \"zlib\"]\n"]:
      let e = addDependency(src, "hello", "uses", "curl")
      checkpoint(e.diagnostic)
      check e.status == desRefused
      check "written inline" in e.diagnostic
      check e.text == src

  test "an entry already in an inline section is present":
    let src = "package hello:\n  uses: [\"nim\", \"zlib >=1.3\"]\n"
    check addDependency(src, "hello", "uses", "zlib").status == desUnchanged
    check addDependency(src, "hello", "uses",
      "zlib >=1.3").status == desUnchanged
    check addDependency(src, "hello", "uses", "zlib >=2").status == desRefused

  test "remove from an inline list says so, not 'not a dependency'":
    for src in ["package hello:\n  uses: [\"nim\", \"zlib\"]\n",
                "package hello:\n  uses: [\n    \"nim\",\n    \"zlib\"]\n"]:
      let r = removeDependency(src, "hello", "zlib")
      checkpoint(r.diagnostic)
      check r.status == desRefused
      check "written inline" in r.diagnostic
      check "not a dependency" notin r.diagnostic
      check r.line == 2
      check r.text == src

  test "a lone inline entry is removed with its header":
    let src = "package hello:\n  uses: \"zlib\"\n  executable hello:\n" &
      "    discard\n"
    check removed(src, "zlib") == "package hello:\n  executable hello:\n" &
      "    discard\n"

suite "names and constraints":


  test "a name is never matched by its prefix":
    let a = added(prefixed, "uses", "openssl >=3.3 <4.0")
    check a == prefixed & "    \"openssl >=3.3 <4.0\"\n"
    check removed(a, "openssl") == prefixed
    check removeDependency(prefixed, "hello", "openssl").status == desNotFound
    check removeDependency(prefixed, "hello", "openssl3").text ==
      "package hello:\n  uses:\n    \"openssl-dev >=1\"\n"

  test "an add of what is there is idempotent":
    let a = added(basic, "uses", "zlib >=1.3")
    for again in ["zlib >=1.3", "zlib   >=1.3", "zlib"]:
      let e = addDependency(a, "hello", "uses", again)
      check e.status == desUnchanged
      check e.text == a
      check e.entry == "zlib >=1.3"
      check e.line == 7

  test "a different constraint is refused, not rewritten":
    let e = addDependency(basic, "hello", "uses", "nim >=2.0")
    check e.status == desRefused
    check e.text == basic
    check "another constraint" in e.diagnostic
    check "line 6" in e.diagnostic
    # The same package in another section is a different entry; `remove`
    # removes it from every section.
    let other = added(basic, "buildDeps", "nim >=2.0")
    check other == basic.replace("  uses:\n",
      "  buildDeps:\n    \"nim >=2.0\"\n  uses:\n")
    let gone = removeDependency(other, "hello", "nim")
    check gone.sections == @["buildDeps", "uses"]
    check gone.text == basic.replace("  uses:\n    \"nim >=2.2 <3.0\"\n", "")

  test "requests":
    check parseDependencyRequest("openssl@>=3.3 <4.0").entry ==
      "openssl >=3.3 <4.0"
    check parseDependencyRequest("openssl   >=3.3   <4.0").entry ==
      "openssl >=3.3 <4.0"
    check parseDependencyRequest("zlib").entry == "zlib"
    # An ecosystem namespace is part of the name, spelled in `uses:` exactly
    # as given (Package-Model.md § Ecosystem namespaces; NPC-M6). Before it
    # was defined, `nimble:zlib` was refused here as a name with a colon.
    let ns = parseDependencyRequest("nimble:chronicles@>=0.10")
    check ns.ok
    check ns.selector == "nimble:chronicles"
    check ns.entry == "nimble:chronicles >=0.10"
    check parseDependencyRequest("nimble:zlib").entry == "nimble:zlib"
    for bad in ["", "@1", "zlib@", "zlib@latest", "-z",
                "zl\"ib", "zlib >=x.y",
                # namespace defects: unknown, empty, no name, two colons,
                # and a name the namespace does not make valid
                "cargo:serde", ":zlib", "nimble:", "nimble:a:b",
                "nimble:-z"]:
      checkpoint bad & ": " & parseDependencyRequest(bad).diagnostic
      check not parseDependencyRequest(bad).ok
    check "no ecosystem defines" in
      parseDependencyRequest("cargo:serde").diagnostic

suite "sections and packages":

  test "creating a section uses the file's nesting step":
    let four = "package hello:\n    buildDeps:\n        \"cmake\"\n" &
      "    executable hello:\n        discard\n"
    check added(four, "uses", "zlib") == "package hello:\n    uses:\n" &
      "        \"zlib\"\n    buildDeps:\n        \"cmake\"\n" &
      "    executable hello:\n        discard\n"
    roundTrips(four, "uses", "zlib")
    roundTrips(four, "buildDeps", "ninja")


  test "a file with several packages needs the package named":
    check packageNamesOf(two) == @["a", "b-c"]
    let none = choosePackage(two, "", "repro.nim")
    check not none.ok
    check none.usage
    check "--package" in none.diagnostic
    check choosePackage(two, "b-c", "repro.nim").name == "b-c"
    let unknown = choosePackage(two, "d", "repro.nim")
    check not unknown.ok
    check not unknown.usage
    check choosePackage(basic, "", "repro.nim").name == "hello"
    # Each package is edited on its own.
    check added(two, "uses", "zlib", "b-c") == two.replace(
      "package `b-c`:\n", "package `b-c`:\n  uses:\n    \"zlib\"\n")
    check added(two, "uses", "zlib", "a") == two.replace(
      "    \"nim\"\n", "    \"nim\"\n    \"zlib\"\n")
    check removeDependency(two, "b-c", "nim").status == desNotFound
    roundTrips(two, "uses", "zlib", "a")
    roundTrips(two, "runtimeDeps", "zlib", "b-c")

  test "the diff names the hunk":
    let a = addDependency(basic, "hello", "uses", "zlib")
    let diff = renderDependencyDiff("repro.nim", basic, a.hunks)
    check diff.startsWith("--- repro.nim\n+++ repro.nim\n@@ -4,6 +4,7 @@\n")
    check "\n+    \"zlib\"\n" in diff

suite "the lock, compared offline":



  test "a lock resolving every entry within its range is consistent":
    let c = compareWithLock(editedRecipe(), "hello", ["uses"],
      lock([("nim", "2.2.4"), ("zlib", "1.3.1")]))
    check c.agreement == laConsistent
    check c.compared == 2

  test "a lock without the added package is stale for exactly it":
    let c = compareWithLock(editedRecipe(), "hello", ["uses"],
      lock([("nim", "2.2.4"), ("zlib", "1.3.1")], unselected = ["zlib"]))
    check c.agreement == laStale
    check c.missing == @["zlib"]
    check c.outside.len == 0

  test "a lock resolving outside the range is stale for exactly that entry":
    let c = compareWithLock(editedRecipe(), "hello", ["uses"],
      lock([("nim", "2.2.4"), ("zlib", "1.2.13")]))
    check c.agreement == laStale
    check c.missing.len == 0
    check c.outside == @["\"zlib >=1.3\" (locked 1.2.13)"]

  test "a removed package the lock still resolves is undecided":
    let after = removed(editedRecipe(), "zlib")
    let c = compareWithLock(after, "hello", ["uses"],
      lock([("nim", "2.2.4"), ("zlib", "1.3.1")]), removed = ["zlib"])
    check c.agreement == laUndecided
    check c.stillLocked == @["zlib 1.3.1"]
    let gone = compareWithLock(after, "hello", ["uses"],
      lock([("nim", "2.2.4")]), removed = ["zlib"])
    check gone.agreement == laConsistent

  test "a removed package another section still names is not reported":
    let both = added(editedRecipe(), "buildDeps", "zlib")
    let after = removeDependency(both, "hello", "zlib")
    check after.sections == @["buildDeps", "uses"]
    let partial = added(basic, "buildDeps", "zlib")
    let c = compareWithLock(partial, "hello", ["uses"],
      lock([("nim", "2.2.4"), ("zlib", "1.3.1")]), removed = ["zlib"])
    check c.agreement == laConsistent

  test "an unreadable lock is said to be unreadable":
    let c = compareWithLock(editedRecipe(), "hello", ["uses"],
      "# not a lock\n")
    check c.agreement == laUnreadable
    check c.diagnostic.len > 0
