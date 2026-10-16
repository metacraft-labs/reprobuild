## GM6: the `repro home compare` allowlist -- every row needs a reason, and
## a row that excuses nothing is stale.
##
## `e2e_compare_allowlist_requires_reasons`, over the fixture pair
## (`tests/fixtures/host-facts/`, one difference per category):
##
## * a row without `reason`, and one whose reason is blank, is refused
##   (exit 2, naming the row and "reason") -- an allowlist entry without a
##   reason is a silent pass (spec §The report);
## * malformed rows are refused rather than ignored (exit 2): an unknown key,
##   an unknown category, a status that can never need an excuse (`same`,
##   `unmapped`), an empty `hosts` list, an unknown top-level key;
## * an `id` ending in `*` matches by prefix (and is stale when no id has
##   the prefix); a bare `*` is refused;
## * a valid row that applies to the host and matches no difference is
##   reported STALE and fails the comparison (exit 1) even when every
##   difference is allowlisted; the same row scoped to another host is
##   neither applied nor stale;
## * a row narrowed by status does not excuse a difference of another
##   status (only-in-nix `jq` is not excused by a `different` row).
##
## Control: the complete, valid allowlist exits 0 -- so each refusal above
## is caused by the one row it adds.
##
## No mocks: the real `build/bin/repro` (compare_support.nim).

import std/[os, strutils, unittest]

import ./compare_support

const ValidRows = """
[[allow]]
category = "packages"
id = "jq"
reason = "fixture: jq is installed by Home Manager only"

[[allow]]
category = "files"
status = "different"
reason = "fixture: the two sides write different shell init"

[[allow]]
category = "environment"
reason = "fixture: Reprobuild-only variables"

[[allow]]
category = "services"
reason = "fixture: Home Manager does not enable the unit"
milestone = "GM6"
"""

suite "GM6: allowlist reasons":

  test "e2e_compare_allowlist_requires_reasons":
    let dir = newScratch("allowlist")
    defer: removeDir(dir)
    let nixPath = dir.writeDoc("nix.json", fixture("nix.json"))
    let reproPath = dir.writeDoc("reprobuild.json", fixture("reprobuild.json"))

    proc compareWith(name, toml: string): CompareRun =
      let path = dir.writeText(name, toml)
      runCompare(["--facts", nixPath, "--facts", reproPath, "--allow", path])

    # Control: the valid allowlist covers every difference.
    let ok = compareWith("valid.toml", ValidRows)
    check ok.exitCode == 0
    check ok.stdout.contains("0 stale allowlist row(s); exit 0")

    # A row without a reason, and one with a blank reason.
    for (name, row) in [("no-reason", "[[allow]]\ncategory = \"packages\"\n"),
                        ("blank-reason", "[[allow]]\ncategory = \"packages\"\n" &
                          "reason = \"   \"\n")]:
      let r = compareWith(name & ".toml", ValidRows & "\n" & row)
      check r.exitCode == 2
      check r.stderr.contains("row 5")
      check r.stderr.contains("`reason` is required")

    # Malformed rows are refused, never ignored.
    for (name, row, needle) in [
        ("unknown-key", "[[allow]]\ncategory = \"files\"\nreason = \"r\"\n" &
          "ids = \"~/.zshrc\"\n", "unknown key `ids`"),
        ("unknown-category", "[[allow]]\ncategory = \"apps\"\nreason = \"r\"\n",
          "unknown category `apps`"),
        ("status-same", "[[allow]]\ncategory = \"files\"\nstatus = \"same\"\n" &
          "reason = \"r\"\n", "cannot be allowlisted"),
        ("status-unmapped", "[[allow]]\ncategory = \"packages\"\n" &
          "status = \"unmapped\"\nreason = \"r\"\n", "cannot be allowlisted"),
        ("empty-hosts", "[[allow]]\ncategory = \"files\"\nreason = \"r\"\n" &
          "hosts = []\n", "`hosts` is empty")]:
      let r = compareWith(name & ".toml", ValidRows & "\n" & row)
      check r.exitCode == 2
      check r.stderr.contains(needle)
    let topLevel = compareWith("top-level.toml", "version = 1\n" & ValidRows)
    check topLevel.exitCode == 2
    check topLevel.stderr.contains("unknown top-level key `version`")

    # A stale row fails even though every difference is allowlisted.
    let staleRow = "[[allow]]\ncategory = \"packages\"\nid = \"ripgrep\"\n" &
      "reason = \"fixture: excuses a difference that does not exist\"\n" &
      "milestone = \"GM8\"\n"
    let stale = compareWith("stale.toml", ValidRows & "\n" & staleRow)
    check stale.exitCode == 1
    check stale.stdout.contains("stale: allow row 5 (packages id=ripgrep)")
    check stale.stdout.contains("0 difference(s) not allowlisted, 1 stale")

    # Scoped to another host: neither applied nor stale.
    let otherHost = compareWith("other-host.toml", ValidRows & "\n" & staleRow &
      "hosts = [\"some-other-host\"]\n")
    check otherHost.exitCode == 0

    # An `id` ending in `*` is a prefix: `~/.zs*` excuses `~/.zshrc`, while
    # `~/.zshx*` (no id starts with it) is stale; a bare `*` is refused.
    let prefixed = compareWith("prefix.toml", ValidRows.replace(
      "status = \"different\"\nreason = \"fixture: the two sides write",
      "id = \"~/.zs*\"\nreason = \"fixture: the two sides write"))
    check prefixed.exitCode == 0
    let prefixStale = compareWith("prefix-stale.toml", ValidRows & "\n" &
      "[[allow]]\ncategory = \"files\"\nid = \"~/.zshx*\"\n" &
      "reason = \"fixture: no id starts with this\"\n")
    check prefixStale.exitCode == 1
    check prefixStale.stdout.contains("stale: allow row 5 (files id=~/.zshx*)")
    let bareStar = compareWith("bare-star.toml", ValidRows & "\n" &
      "[[allow]]\ncategory = \"files\"\nid = \"*\"\nreason = \"r\"\n")
    check bareStar.exitCode == 2
    check bareStar.stderr.contains("matches every entry")

    # A status-narrowed row does not excuse another status.
    let narrowed = compareWith("narrowed.toml", ValidRows.replace(
      "id = \"jq\"", "status = \"different\""))
    check narrowed.exitCode == 1
    check narrowed.stdout.contains("only-in-nix")
    check narrowed.stdout.contains("1 difference(s) not allowlisted, 1 stale")
