## The pin a repository records for a sibling is read from its `flake.lock`
## too, not only from its `repro.lock` and `.github/sibling-repos`.
##
## Spec: Unified-Locking-And-Hooks.md §13.5, "The sources a recipe compile
## reads" (amended 2026-11-22); Nix-Flake-Coexistence.md §3.2. reprobuild's
## `flake.lock` pins io-mon, nim-shm-gset and runquota, which its `repro.lock`
## does not list. `.github/sibling-repos` repeats those three today, but it is
## a second copy that may name only a branch (`codetracer=dev`) or omit an
## input altogether (`nim-stew`), and the flake input is the tree the
## development shell actually exports. The lookup feeds the stale-sibling
## judgement that keeps a sibling far behind the pinned io-mon out of the dev
## env's interface extraction (measured 2026-11-21, `repro exec` in a
## reprobuild checkout).
##
## A pure routine over text, so the fixtures are text: lock files shaped as
## Nix writes them (version 7: `nodes`, each with `inputs` / `locked` /
## `original`, and `root`). No mocks.

import std/unittest

import repro_core/sibling_source_policy

const
  PinIoMon = "b1c32599f9cd671b150f68de2b21bdc9ae0c42be"
  TransitiveIoMon = "5477f9f1aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  PinBearssl = "9a4eed052abbded2d94feaf3f5bbd95a30ec4671"
  PinRunquota = "6ff973131e7f715f0237cb0f08b8dd16cbeba0dc"
  PinLock = "c34e3252d413361a0f250d8921e00c119d30e114"

proc githubNode(repo, rev: string; inputs = ""): string =
  "{ " & (if inputs.len > 0: "\"inputs\": {" & inputs & "}, " else: "") &
    "\"locked\": { \"lastModified\": 1795333081, \"narHash\": \"sha256-x=\", " &
    "\"owner\": \"metacraft-labs\", \"repo\": \"" & repo & "\", \"rev\": \"" &
    rev & "\", \"type\": \"github\" }, \"original\": { \"owner\": " &
    "\"metacraft-labs\", \"repo\": \"" & repo & "\", \"type\": \"github\" } }"

proc flakeLock(rootInputs, nodes: string): string =
  "{\n  \"nodes\": {\n" & nodes & ",\n    \"root\": { \"inputs\": {" &
    rootInputs & "} }\n  },\n  \"root\": \"root\",\n  \"version\": 7\n}\n"

# The direct `io-mon-src` input pins `PinIoMon`; `other-dep` carries its own
# io-mon input at `TransitiveIoMon`, which is that flake's choice. `nixpkgs`
# is taken by `follows` (a list). `bearssl-src` is a `git` input whose URL
# ends in `.git` and carries a query.
const fixture = flakeLock(
  "\"io-mon-src\": \"io-mon-src\", \"other-dep\": \"other-dep\", " &
    "\"nixpkgs\": [\"other-dep\", \"nixpkgs\"], " &
    "\"bearssl-src\": \"bearssl-src\", \"runquota-src\": \"runquota-src\"",
  "    \"io-mon-src\": " & githubNode("io-mon", PinIoMon) & ",\n" &
  "    \"io-mon-src_2\": " & githubNode("io-mon", TransitiveIoMon) & ",\n" &
  "    \"other-dep\": " & githubNode("other-dep", PinLock,
    "\"io-mon\": \"io-mon-src_2\", \"nixpkgs\": \"nixpkgs\"") & ",\n" &
  "    \"nixpkgs\": " & githubNode("nixpkgs", PinLock) & ",\n" &
  "    \"bearssl-src\": { \"flake\": false, \"locked\": { \"lastModified\": 1, " &
    "\"narHash\": \"sha256-y=\", \"rev\": \"" & PinBearssl & "\", " &
    "\"type\": \"git\", \"url\": " &
    "\"https://github.com/status-im/nim-bearssl.git?shallow=1\" }, " &
    "\"original\": { \"type\": \"git\", \"url\": " &
    "\"https://github.com/status-im/nim-bearssl\" } },\n" &
  "    \"runquota-src\": " & githubNode("runquota", PinRunquota))

suite "the sibling pin lookup reads flake.lock":
  test "a direct input is matched by the repository it fetches":
    check pinnedFlakeInputRevisionIn(fixture, "io-mon") == PinIoMon
    check pinnedFlakeInputRevisionIn(fixture, "runquota") == PinRunquota
    # Not by the input's name.
    check pinnedFlakeInputRevisionIn(fixture, "io-mon-src") == ""
    # Case does not decide it (forge repository names are case-insensitive).
    check pinnedFlakeInputRevisionIn(fixture, "IO-MON") == PinIoMon

  test "a git input is matched by its URL's last component":
    check pinnedFlakeInputRevisionIn(fixture, "nim-bearssl") == PinBearssl

  test "transitive and follows inputs are another flake's choice":
    # `other-dep`'s own io-mon input is not this repository's pin.
    check pinnedFlakeInputRevisionIn(fixture, "io-mon") != TransitiveIoMon
    # `nixpkgs` is reached only through `follows`; `other-dep` is direct.
    check pinnedFlakeInputRevisionIn(fixture, "nixpkgs") == ""
    check pinnedFlakeInputRevisionIn(fixture, "other-dep") == PinLock

  test "two direct inputs of one repository at two revisions pin nothing":
    let ambiguous = flakeLock(
      "\"io-mon-src\": \"io-mon-src\", \"io-mon-old\": \"io-mon-old\"",
      "    \"io-mon-src\": " & githubNode("io-mon", PinIoMon) & ",\n" &
      "    \"io-mon-old\": " & githubNode("io-mon", TransitiveIoMon))
    check pinnedFlakeInputRevisionIn(ambiguous, "io-mon") == ""
    let agreeing = flakeLock(
      "\"io-mon-src\": \"io-mon-src\", \"io-mon-too\": \"io-mon-too\"",
      "    \"io-mon-src\": " & githubNode("io-mon", PinIoMon) & ",\n" &
      "    \"io-mon-too\": " & githubNode("io-mon", PinIoMon))
    check pinnedFlakeInputRevisionIn(agreeing, "io-mon") == PinIoMon

  test "an empty or malformed lock pins nothing":
    check pinnedFlakeInputRevisionIn("", "io-mon") == ""
    check pinnedFlakeInputRevisionIn("{ \"nodes\": { \"io-mon-src\": ",
      "io-mon") == ""
    check pinnedFlakeInputRevisionIn("not json", "io-mon") == ""
    check flakeLockDirectPins(fixture[0 ..< fixture.len div 2]).len == 0

  test "repro.lock first, then flake.lock, then .github/sibling-repos":
    let pins = flakeLockDirectPins(fixture)
    let reproLock = "[lock]\ndeps = [{ name = \"io-mon\", coord_kind = " &
      "\"vcs\", url = \"https://example.invalid/io-mon\", revision = \"" &
      PinLock & "\" }]\n"
    let siblingRepos = "# comment\nio-mon=dev\nrunquota=agents\ngosti=" &
      PinLock & "\n"
    check pinnedSiblingRevisionIn(reproLock, pins, siblingRepos,
      "io-mon") == PinLock
    check pinnedSiblingRevisionIn("", pins, siblingRepos,
      "io-mon") == PinIoMon
    check pinnedSiblingRevisionIn("", pins, siblingRepos,
      "runquota") == PinRunquota
    check pinnedSiblingRevisionIn("", pins, siblingRepos, "gosti") == PinLock
    check pinnedSiblingRevisionIn("", [], siblingRepos, "io-mon") == "dev"
    check pinnedSiblingRevisionIn("", pins, "", "absent") == ""
