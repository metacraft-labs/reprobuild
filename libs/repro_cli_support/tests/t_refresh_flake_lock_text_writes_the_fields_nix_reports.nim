## `refreshFlakeLockText` — the pure half of NF-2's `flake.lock` refresh —
## moves a pin ONLY together with the derived fields nix reported for the new
## revision, and writes them where nix's own lock writer would.
##
## Issue: reprobuild-pm `issues/2026-09-27-pre-commit-hook-repins-flake-lock-
## at-a-sibling-head-and-drops-narhash.md`. The refresh used to DELETE
## `narHash` / `lastModified` / `revCount` from every node whose `rev` it
## moved, leaving a node weaker than the one it replaced. It now takes the
## fields nix reports (per input, from the caller) and:
##
##   1. with no fields for an input, does NOT move it: the input comes back in
##      `pending` carrying the exact attributes to ask nix about — the locked
##      node with `rev` moved and the derived fields and `dir` removed — and
##      the document is unchanged;
##   2. with fields, REPLACES them in place in a node that has them, keeping
##      every other byte of the document;
##   3. INSERTS them, at nix's sorted key position, into a `rev`-only node (the
##      shape the old refresh wrote), producing exactly the node nix writes;
##   4. REMOVES a derived field nix does not report for the new revision;
##   5. leaves an unmoved pin alone (nothing pending, nothing rewritten).
##
## And `flakeRevisionFetchExpr` asks fetchTree for a NON-shallow git fetch
## (fetchTree's default is shallow, which reports no `revCount`), and embeds
## the attributes so no `${` or `"` in them can break out of the string.
##
## Test-double policy: NO mocks. Pure functions over literal lock text; the
## nix invocation itself is covered by the integration cases
## `t_a_refreshed_flake_pin_carries_what_nix_would_write` and
## `t_an_unfetchable_flake_revision_is_withheld`.

import std/[json, strutils, tables, unittest]

import repro_cli_support

const
  oldRev = "1111111111111111111111111111111111111111"
  newRev = "2222222222222222222222222222222222222222"

proc lockWith(lockedBody: string): string =
  "{\n" &
  "  \"nodes\": {\n" &
  "    \"alpha-src\": {\n" &
  "      \"locked\": {\n" & lockedBody & "\n      },\n" &
  "      \"original\": {\n" &
  "        \"ref\": \"main\",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"file:///origin/alpha.git\"\n" &
  "      }\n" &
  "    },\n" &
  "    \"root\": {\n" &
  "      \"inputs\": {\n" &
  "        \"alpha-src\": \"alpha-src\"\n" &
  "      }\n" &
  "    }\n" &
  "  },\n" &
  "  \"root\": \"root\",\n" &
  "  \"version\": 7\n" &
  "}\n"

proc fullNode(rev, narHash: string; lastModified, revCount: int): string =
  "        \"dir\": \"sub\",\n" &
  "        \"lastModified\": " & $lastModified & ",\n" &
  "        \"narHash\": \"" & narHash & "\",\n" &
  "        \"ref\": \"main\",\n" &
  "        \"rev\": \"" & rev & "\",\n" &
  "        \"revCount\": " & $revCount & ",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"file:///origin/alpha.git\""

proc revOnlyNode(rev: string): string =
  "        \"ref\": \"main\",\n" &
  "        \"rev\": \"" & rev & "\",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"file:///origin/alpha.git\""

proc fieldsFromNix(narHash: string; lastModified, revCount: int): JsonNode =
  result = %*{"narHash": narHash, "lastModified": lastModified}
  if revCount >= 0: result["revCount"] = %revCount

suite "refreshFlakeLockText writes the fields nix reports":

  test "no fields from nix: the pin does not move, and the ask is exact":
    let before = lockWith(fullNode(oldRev, "sha256-OLD=", 100, 1))
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: newRev)])
    check not r.failed
    check not r.changed
    check r.text == before
    check r.rewrites.len == 0
    check r.pending.len == 1
    let p = r.pending[0]
    check p.input == "alpha-src"
    check p.oldRev == oldRev
    check p.newRev == newRev
    check p.fetchAttrs == %*{"ref": "main", "rev": newRev, "type": "git",
                              "url": "file:///origin/alpha.git"}

  test "fields from nix replace the old ones in place":
    let before = lockWith(fullNode(oldRev, "sha256-OLD=", 100, 1))
    var derived = initTable[string, JsonNode]()
    derived["alpha-src"] = fieldsFromNix("sha256-NEW=", 200, 2)
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: newRev)],
      derived = derived)
    check r.changed
    check r.pending.len == 0
    check r.text == lockWith(fullNode(newRev, "sha256-NEW=", 200, 2))
    check r.rewrites.len == 1
    check r.rewrites[0].recomputed == @["narHash", "lastModified", "revCount"]
    check r.rewrites[0].dropped.len == 0

  test "fields from nix are inserted into a rev-only node at nix's positions":
    let before = lockWith(revOnlyNode(oldRev))
    var derived = initTable[string, JsonNode]()
    derived["alpha-src"] = fieldsFromNix("sha256-NEW=", 200, 2)
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: newRev)],
      derived = derived)
    check r.changed
    let expected = lockWith(
      "        \"lastModified\": 200,\n" &
      "        \"narHash\": \"sha256-NEW=\",\n" &
      "        \"ref\": \"main\",\n" &
      "        \"rev\": \"" & newRev & "\",\n" &
      "        \"revCount\": 2,\n" &
      "        \"type\": \"git\",\n" &
      "        \"url\": \"file:///origin/alpha.git\"")
    if r.text != expected:
      checkpoint("got:\n" & r.text & "\nexpected:\n" & expected)
    check r.text == expected

  test "an insertion after the last member goes last":
    # Every derived key sorts before `ref`, so to exercise the tail position
    # the node is cut down to members that all sort first.
    let before = lockWith(
      "        \"lastModified\": 100,\n" &
      "        \"rev\": \"" & oldRev & "\"")
    var derived = initTable[string, JsonNode]()
    derived["alpha-src"] = fieldsFromNix("sha256-NEW=", 200, 7)
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: newRev)],
      derived = derived)
    check r.text == lockWith(
      "        \"lastModified\": 200,\n" &
      "        \"narHash\": \"sha256-NEW=\",\n" &
      "        \"rev\": \"" & newRev & "\",\n" &
      "        \"revCount\": 7")

  test "a derived field nix no longer reports is removed":
    let before = lockWith(fullNode(oldRev, "sha256-OLD=", 100, 1))
    var derived = initTable[string, JsonNode]()
    derived["alpha-src"] = fieldsFromNix("sha256-NEW=", 200, -1)
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: newRev)],
      derived = derived)
    check r.changed
    check r.rewrites[0].dropped == @["revCount"]
    check not r.text.contains("revCount")
    check parseJson(r.text)["nodes"]["alpha-src"]["locked"]["narHash"].getStr() ==
      "sha256-NEW="

  test "an unmoved pin is neither pending nor rewritten":
    let before = lockWith(fullNode(oldRev, "sha256-OLD=", 100, 1))
    let r = refreshFlakeLockText(before, [(input: "alpha-src", rev: oldRev)])
    check not r.changed
    check r.pending.len == 0
    check r.rewrites.len == 0
    check r.text == before

suite "flakeRevisionFetchExpr":

  test "a git node is fetched non-shallow unless it says otherwise":
    let expr = flakeRevisionFetchExpr(%*{"type": "git", "rev": newRev,
      "url": "file:///o.git"})
    check expr.contains("\\\"shallow\\\":false")
    let shallow = flakeRevisionFetchExpr(%*{"type": "git", "rev": newRev,
      "url": "file:///o.git", "shallow": true})
    check shallow.contains("\\\"shallow\\\":true")
    check not shallow.contains("\\\"shallow\\\":false")
    let github = flakeRevisionFetchExpr(%*{"type": "github", "rev": newRev,
      "owner": "o", "repo": "r"})
    check not github.contains("shallow")

  test "attribute text cannot open an interpolation or end the string":
    let expr = flakeRevisionFetchExpr(%*{"type": "github", "rev": newRev,
      "owner": "a${builtins.abort \"x\"}", "repo": "r"})
    # Every `${` is escaped as `\${`, and every quote of the payload as `\"`.
    check expr.contains("\\${")
    check not expr.replace("\\${", "").contains("${")
    check expr.contains("\\\\\\\"x\\\\\\\"")
