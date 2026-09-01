## NF-2 (Nix-Flake-Coexistence.md §4; Nix-Flake-Coexistence.milestones.org
## §NF-2) — **only the overridden nodes are rewritten**.
##
##   > Concretely, the refresh rewrites the `locked` node of each input that an
##   > override substituted, to the sibling's current revision, **leaving every
##   > other node untouched**.
##
## ## Why this is asserted at the BYTE level
##
## `flake.lock` is nix's file. A refresh that parsed it and serialised it back
## would produce a document that is JSON-equal and byte-different: keys
## renormalised, indentation unified, `nixpkgs` reindented for no reason at
## all. The consequences are not cosmetic —
##
##   * a one-line pin move becomes a whole-file diff, which is unreviewable and
##     conflicts with every other branch that touched the lock;
##   * it defeats the property the case next door asserts: a document that is
##     rewritten wholesale is rewritten on every commit that touches ANY input.
##
## So the fixture's lock is deliberately NOT uniformly formatted. `nixpkgs` is
## written with its members in a non-alphabetical order and at a different
## indent from every other node, and `flake-utils` carries a single-line
## `original`. Nothing about either changes here, so both must come out of the
## refresh byte for byte — which no parse-and-serialise round trip can do.
##
## ## What is asserted
##
##   1. the refreshed file equals, BYTE FOR BYTE, the original with exactly two
##      node substitutions applied — nothing else in the document moves;
##   2. `gamma-src` (an overridden input whose sibling did NOT move), `nixpkgs`,
##      `flake-utils` and the `root` node are each byte-identical;
##   3. exactly two `rev` values differ between the two documents.
##
## ## Mutation (from the milestone): re-serialize the whole document ⇒ RED
##
## `writeFile(lock, pretty(parseJson(text), indent = 2))` reindents `nixpkgs`
## and rewrites `flake-utils`'s single-line object across four lines. Assert (1)
## fails on the whole-file comparison and assert (2) names the specific node.
##
## Test-double policy: NO mocks, doubles or fakes. See the header of
## `nf2_flake_lock_fixture.nim`.

import std/[os, strutils, unittest]

import nf2_flake_lock_fixture

proc refreshedNodeText(name, url, rev: string): string =
  ## What the fixture's node becomes once its pin moves: the same node with
  ## `rev` replaced and the three fields DERIVED from the previous revision's
  ## content removed. Written out longhand rather than computed, so this file
  ## states the expected result independently of the implementation that
  ## produces it.
  "    \"" & name & "\": {\n" &
  "      \"locked\": {\n" &
  "        \"ref\": \"main\",\n" &
  "        \"rev\": \"" & rev & "\",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & url & "\"\n" &
  "      },\n" &
  "      \"original\": {\n" &
  "        \"ref\": \"main\",\n" &
  "        \"type\": \"git\",\n" &
  "        \"url\": \"" & url & "\"\n" &
  "      }\n" &
  "    }"

proc revCount(text: string): int =
  for line in text.splitLines():
    if line.strip().startsWith("\"rev\":"): inc result

suite "NF-2: only overridden nodes are rewritten":

  test "t_only_overridden_nodes_are_rewritten":
    if not nf2Prerequisites("t_only_overridden_nodes_are_rewritten"):
      skip()
    else:
      let fx = setupNf2Fixture("surgical")
      defer: removeDir(fx.scratch)
      isolateNf2Config(fx)
      defer: releaseNf2Config()

      let before = readFile(lockPath(fx))
      # Five inputs; three of them are backed by workspace checkouts and are
      # therefore substituted; two of THOSE move.
      check before.contains("\"nixpkgs\"")
      check before.contains("\"flake-utils\"")
      check revCount(before) == 5

      let newAlpha = moveSibling(fx, "alpha", "revision 2")
      let newBeta = moveSibling(fx, "beta", "revision 2")

      let commit = tryCommitInApp(fx, "move two of five")
      if commit.code != 0:
        checkpoint("git commit failed:\n" & commit.output)
      check commit.code == 0
      let after = readFile(lockPath(fx))
      # The surgery survives the round trip through git's object store too:
      # what the commit carries is the same bytes, not a re-normalisation.
      check lockInCommit(fx) == after

      # ---- (1) byte-for-byte: the original with exactly two substitutions --
      let expected = before
        .replace(nodeText(before, "alpha-src"),
          refreshedNodeText("alpha-src", originUrl(fx, "alpha"), newAlpha)
            .strip(leading = true, trailing = false))
        .replace(nodeText(before, "beta-src"),
          refreshedNodeText("beta-src", originUrl(fx, "beta"), newBeta)
            .strip(leading = true, trailing = false))
      if after != expected:
        checkpoint(
          "\n--- expected ---\n" & expected & "\n--- actual ---\n" & after)
      check after == expected

      # ---- (2) each untouched node, named individually. -------------------
      # Stated one by one as well as through (1) so a failure says WHICH node
      # a re-serializer disturbed rather than only that the file differs.
      check nodeText(after, "gamma-src") == nodeText(before, "gamma-src")
      check nodeText(after, "nixpkgs") == nodeText(before, "nixpkgs")
      check nodeText(after, "flake-utils") == nodeText(before, "flake-utils")
      check nodeText(after, "root") == nodeText(before, "root")
      # `nixpkgs`'s deliberately odd shape, asserted directly: its members are
      # in non-alphabetical order and at a deeper indent than every other node.
      check after.contains(
        "                \"type\": \"github\",\n" &
        "                \"rev\": \"5e4fbfb6b3de1aa2872b76d49fafc942626e2add\",")
      # …and `flake-utils`'s single-line object survived as one line.
      check after.contains(
        "      \"original\": { \"owner\": \"numtide\", \"repo\": " &
        "\"flake-utils\", \"type\": \"github\" }")

      # ---- (3) exactly two revisions differ. ------------------------------
      check revCount(after) == 5
      var differing = 0
      let beforeLines = before.splitLines()
      let afterLines = after.splitLines()
      for line in afterLines:
        if line.strip().startsWith("\"rev\":") and line notin beforeLines:
          inc differing
      check differing == 2
