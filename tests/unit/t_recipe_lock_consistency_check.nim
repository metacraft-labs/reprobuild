## The H1 / H2 consistency check (`repro_cli_support/lock_consistency`) and the
## `uses:` text scan it rests on (`scanReproUsesDeclarations`), as pure
## functions over the texts a commit or a push carries
## (Unified-Locking-And-Hooks.md §16.3).
##
## WHY a unit test beside the integration cases
## (`t_recipe_lock_consistency_refuses`): the integration cases drive the real
## hooks over `git+file://` fixtures, and cannot use a `github:` URL. The shape
## that motivated H2 is exactly that one: reprobuild's own `flake.nix` pins
## `nim-stackable-hooks-src` as `github:metacraft-labs/nim-stackable-hooks/
## <sha>` (a path-form pin) while its `repro.lock` resolves
## `https://github.com/metacraft-labs/nim-stackable-hooks` under the name
## `nim-stackable-hooks` at another revision. The first case below is that
## shape, byte for byte in the parts that matter.
##
## What is covered:
##   * H2 across URL spellings and names (`github:o/r/<sha>` against
##     `https://github.com/o/r`), and its path-form remedy (`/<sha>`, not
##     `rev=`);
##   * no H2 for one name naming two repositories, or for a repository only
##     one lock resolves;
##   * H1 for a flake: an exact pin locked elsewhere; `original.rev` against
##     `locked.rev` with no recipe pin; a consistent exact pin passes;
##   * H1 for a repro.lock: a version outside its range; inside it passes; an
##     unselected instance is not held to the range; a conditional entry is
##     reported as not checked;
##   * an exact `uses:` version against the producer's `sourceRevision`, and
##     H2's constraint comparison when both recipes pin one repository;
##   * an exact version cut (`sourceRepository`) from another repository than
##     the lock entry fetches is not compared, and says so;
##   * an unreadable lock, and a resolved version the range grammar cannot
##     read, are named rather than passed or refused;
##   * the commit-time re-pin verdict (H3): a range that excludes the
##     version its producer maps the observed revision to, an unmapped
##     revision listed as not checked, an exact version's pin, and the
##     refusal text with and without an explicit develop override;
##   * the `uses:` scan: block and inline forms, nested policy blocks,
##     `when` / `case` arms, comments and triple-quoted strings.
##
## Test-double policy: the two lookups the check takes (a producer's
## `versions:` table, a git ref resolved in a checkout) are supplied as
## closures over literal data. They stand in for reading a sibling's
## `repro.nim` and running `git rev-parse` in it, which is I/O the integration
## cases perform for real; the logic under test — every comparison and every
## message — is the production code, unmocked.

import std/[strutils, unittest]

import repro_cli_support/lock_consistency

const
  ShaA = "600f2a80c9e582e860d36be20c04b9c74263458d"
  ShaB = "3af63afc5c0b55a27fc5e0a26f3a32833caf8873"
  ShaC = "a3564c13e0b7d0c6a092c19c998cd3faee5ce20a"

proc text(path, body: string): ConsistencyText =
  ConsistencyText(present: true, path: path, text: body)

proc githubNode(owner, repo, rev: string; originalRev = ""): string =
  "{ \"locked\": { \"lastModified\": 1, \"narHash\": \"sha256-x\", " &
    "\"owner\": \"" & owner & "\", \"repo\": \"" & repo & "\", \"rev\": \"" &
    rev & "\", \"type\": \"github\" }, \"original\": { \"owner\": \"" & owner &
    "\", \"repo\": \"" & repo & "\"" &
    (if originalRev.len > 0: ", \"rev\": \"" & originalRev & "\"" else: "") &
    ", \"type\": \"github\" } }"

proc flakeLock(nodes: openArray[(string, string)]): string =
  var parts, inputs: seq[string]
  for (name, node) in nodes:
    parts.add("\"" & name & "\": " & node)
    inputs.add("\"" & name & "\": \"" & name & "\"")
  "{ \"nodes\": { " & parts.join(", ") & ", \"root\": { \"inputs\": { " &
    inputs.join(", ") & " } } }, \"root\": \"root\", \"version\": 7 }"

proc dep(name, path, url, rev: string): string =
  "{ name = \"" & name & "\", path = \"" & path & "\", coord_kind = \"vcs\", " &
    "url = \"" & url & "\", revision = \"" & rev &
    "\", integrity = \"git-sha1:" & rev & "\", version = \"\", " &
    "visibility = \"public\", participation = \"\", depends = \"\", " &
    "tags = \"\" }"

proc reproLock(deps: openArray[string]; packages = "";
    platform = "amd64-linux"; variants = ""): string =
  "schema = \"reprobuild.solved-graph-lock.v2\"\n\n[lock]\n" &
    "platform = \"" & platform & "\"\noptimal = false\n" &
    "inputs_digest = \"fnv1a64:0\"\nvariants = [" & variants & "]\n" &
    "packages = [" & packages & "]\n" &
    "deps = [" & @deps.join(", ") & "]\n"

proc pkg(name, version: string; selection = "selected"): string =
  "{ name = \"" & name & "\", version = \"" & version & "\", source = \"" &
    name & "\", selection = \"" & selection & "\" }"

const ReprobuildFlakeNix = """
{
  inputs = {
    nim-shm-queue-src = {
      url = "github:metacraft-labs/nim-shm-queue";
      flake = false;
    };
    nim-stackable-hooks-src = {
      # a release pin, with a reason
      url = "github:metacraft-labs/nim-stackable-hooks/600f2a80c9e582e860d36be20c04b9c74263458d";
      flake = false;
    };
  };
  outputs = _: { };
}
"""

proc reprobuildInputs(stackableRev: string): ConsistencyInputs =
  result.repoRoot = "/w/reprobuild"
  result.lockPathBase = "/w/reprobuild"
  result.flakeNix = text("/w/reprobuild/flake.nix", ReprobuildFlakeNix)
  result.flakeLock = text("/w/reprobuild/flake.lock", flakeLock([
    ("nim-shm-queue-src", githubNode("metacraft-labs", "nim-shm-queue", ShaC)),
    ("nim-stackable-hooks-src", githubNode("metacraft-labs",
      "nim-stackable-hooks", ShaA, originalRev = ShaA))]))
  result.reproLock = text("/w/reprobuild/repro.lock", reproLock([
    dep("nim-shm-queue", "../nim-shm-queue",
      "https://github.com/metacraft-labs/nim-shm-queue", ShaC),
    dep("nim-stackable-hooks", "../nim-stackable-hooks",
      "https://github.com/metacraft-labs/nim-stackable-hooks", stackableRev),
    dep("reprobuild", ".", "https://github.com/metacraft-labs/reprobuild",
      ShaB)]))

suite "H2: the two locks agree, by canonical repository URL":

  test "reprobuild's own shape: a path-form github pin against an https repro.lock entry":
    let r = checkRecipeLockConsistency(reprobuildInputs(ShaB))
    check r.diagnostics.len == 0
    check r.violationsOf(crH1).len == 0
    let h2 = r.violationsOf(crH2)
    check h2.len == 1
    if h2.len == 1:
      let v = h2[0]
      check v.repository == "github.com/metacraft-labs/nim-stackable-hooks"
      check v.dependency == "nim-stackable-hooks"
      check v.recipeLine == 9
      check v.summary == "H2 (the two locks agree): repository " &
        "github.com/metacraft-labs/nim-stackable-hooks is resolved by " &
        "/w/reprobuild/repro.lock as 'nim-stackable-hooks' at " & ShaB &
        " and by /w/reprobuild/flake.lock as input 'nim-stackable-hooks-src'" &
        " at " & ShaA & " (pinned by /w/reprobuild/flake.nix:9 at " & ShaA &
        ")"
      let msg = renderConsistencyViolation(v)
      # The path-form pin is edited as a path component, not as `rev=`.
      check ("changes /" & ShaA & " to /" & ShaB) in msg
      check "rev=" & ShaA notin msg
      check ("change the 'nim-stackable-hooks' entry's revision and its " &
        "git-sha1 integrity from " & ShaB & " to " & ShaA) in msg
      check "`nix flake lock /w/reprobuild`" in msg
      # Both directions are the runnable `repro lock update`, one per target.
      check ("To make both locks name " & ShaA & " (the flake's revision), " &
        "run `repro lock update nim-stackable-hooks --to " & ShaA &
        " --repo-root=/w/reprobuild`, which moves every resolution of the " &
        "repository to it") in msg
      check ("To make both locks name " & ShaB & " (the repro.lock " &
        "revision), run `repro lock update nim-stackable-hooks-src --to " &
        ShaB & " --repo-root=/w/reprobuild`: it changes /" & ShaA & " to /" &
        ShaB) in msg
      check "not available yet" notin msg
      check "<rev>" notin msg
      check v.evidence == "rule=H2 repository=github.com/metacraft-labs/" &
        "nim-stackable-hooks repro.lock=nim-stackable-hooks@" & ShaB &
        " flake.lock=nim-stackable-hooks-src@" & ShaA &
        " recipe=/w/reprobuild/flake.nix:9"

  test "the same shape with the locks agreeing passes":
    let r = checkRecipeLockConsistency(reprobuildInputs(ShaA))
    check r.violations.len == 0

  test "one name for two repositories is not compared":
    var inputs = reprobuildInputs(ShaA)
    # A repro.lock entry CALLED like the flake input, fetching another
    # repository at another revision.
    inputs.reproLock = text("/w/reprobuild/repro.lock", reproLock([
      dep("nim-stackable-hooks-src", "../other",
        "https://github.com/someone-else/nim-stackable-hooks", ShaB)]))
    let r = checkRecipeLockConsistency(inputs)
    check r.violations.len == 0

  test "a repository only one lock resolves is not compared":
    var inputs = reprobuildInputs(ShaA)
    inputs.reproLock = text("/w/reprobuild/repro.lock", reproLock([
      dep("runquota", "../runquota", "https://github.com/metacraft-labs/runquota",
        ShaB)]))
    check checkRecipeLockConsistency(inputs).violations.len == 0

  test "without a repro.lock there is nothing to compare":
    var inputs = reprobuildInputs(ShaB)
    inputs.reproLock = ConsistencyText()
    check checkRecipeLockConsistency(inputs).violations.len == 0

  test "an unreadable lock is a named diagnostic, never a silent pass":
    var inputs = reprobuildInputs(ShaB)
    inputs.flakeLock = text("/w/reprobuild/flake.lock", "{ not json")
    inputs.reproLock = text("/w/reprobuild/repro.lock", "not a lock")
    let r = checkRecipeLockConsistency(inputs)
    check r.violations.len == 0
    check r.diagnostics.len == 2
    if r.diagnostics.len == 2:
      check r.diagnostics[0].startsWith("/w/reprobuild/flake.lock could not " &
        "be read as a flake lock")
      check r.diagnostics[1].startsWith("/w/reprobuild/repro.lock could not " &
        "be read as a lock")

suite "H1: a flake.lock satisfies flake.nix":

  test "an exact pin locked at another revision is H1, with both remedies":
    var inputs = reprobuildInputs(ShaA)
    inputs.reproLock = ConsistencyText()
    inputs.flakeLock = text("/w/reprobuild/flake.lock", flakeLock([
      ("nim-stackable-hooks-src", githubNode("metacraft-labs",
        "nim-stackable-hooks", ShaB, originalRev = ShaA))]))
    let r = checkRecipeLockConsistency(inputs)
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    check r.violationsOf(crH2).len == 0
    if h1.len == 1:
      let msg = renderConsistencyViolation(h1[0])
      check msg.startsWith("H1 (the lock satisfies the recipe): " &
        "/w/reprobuild/flake.nix:9 pins input 'nim-stackable-hooks-src' at " &
        "revision " & ShaA & ", but /w/reprobuild/flake.lock locks it at " &
        ShaB & " (node 'nim-stackable-hooks-src', locked.rev; its original.rev " &
        "records " & ShaA & ")")
      check "`nix flake update nim-stackable-hooks-src --flake /w/reprobuild`" in
        msg
      check ("If " & ShaB & " is the intended upgrade, run `repro lock " &
        "update nim-stackable-hooks-src --to " & ShaB & " --repo-root=" &
        "/w/reprobuild`: it changes /" & ShaA & " to /" & ShaB & " in that " &
        "input's url in /w/reprobuild/flake.nix") in msg
      check "not available yet" notin msg
      check "stale" notin msg.toLowerAscii()

  test "original.rev against locked.rev with no recipe pin is H1":
    var inputs = reprobuildInputs(ShaA)
    inputs.reproLock = ConsistencyText()
    inputs.flakeLock = text("/w/reprobuild/flake.lock", flakeLock([
      ("nim-shm-queue-src", githubNode("metacraft-labs", "nim-shm-queue", ShaC,
        originalRev = ShaB)),
      ("nim-stackable-hooks-src", githubNode("metacraft-labs",
        "nim-stackable-hooks", ShaA, originalRev = ShaA))]))
    let h1 = checkRecipeLockConsistency(inputs).violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1:
      check h1[0].dependency == "nim-shm-queue-src"
      check h1[0].summary == "H1 (the lock satisfies the recipe): " &
        "/w/reprobuild/flake.lock node 'nim-shm-queue-src' for input " &
        "'nim-shm-queue-src' records original.rev " & ShaB &
        " but locked.rev " & ShaC & "; /w/reprobuild/flake.nix:4 states " &
        "github:metacraft-labs/nim-shm-queue"

  test "a consistent exact pin and a floating input pass":
    var inputs = reprobuildInputs(ShaA)
    inputs.reproLock = ConsistencyText()
    check checkRecipeLockConsistency(inputs).violations.len == 0

suite "H1: a repro.lock satisfies repro.nim":

  const Recipe = "import repro_project_dsl\n\npackage app:\n  uses:\n" &
    "    \"nim >=2.2 <3.0\"   # the toolchain floor\n" &
    "    \"gcc >=12\"\n" &
    "    when defined(macosx):\n" &
    "      \"clang >=99\"\n" &
    "    \"actionlint\"\n"

  proc reproInputs(packages: string; recipe = Recipe): ConsistencyInputs =
    result.repoRoot = "/w/app"
    result.lockPathBase = "/w/app"
    result.reproNim = text("/w/app/repro.nim", recipe)
    result.reproLock = text("/w/app/repro.lock", reproLock([
      dep("app", ".", "https://example.invalid/app", ShaA)], packages))

  test "a resolution outside its range is H1, naming the line and the version":
    let r = checkRecipeLockConsistency(reproInputs(
      pkg("nim", "2.0.8") & ", " & pkg("gcc", "13.1.0") & ", " &
      pkg("clang", "1.0.0")))
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1:
      check h1[0].summary == "H1 (the lock satisfies the recipe): " &
        "/w/app/repro.nim:5 requires 'nim >=2.2 <3.0' (uses:), but " &
        "/w/app/repro.lock resolves package 'nim' at version 2.0.8, which " &
        "that range does not admit"
      check "From /w/app run: `repro lock refresh`" in
        renderConsistencyViolation(h1[0])
    # The `when defined(macosx)` arm does not apply to this amd64-linux lock,
    # so its `clang >=99` is not held against clang 1.0.0 (the one violation
    # above is nim's) — decided, so nothing is left unchecked either.
    check r.notChecked.len == 0

  test "resolutions inside their ranges pass":
    let r = checkRecipeLockConsistency(reproInputs(
      pkg("nim", "2.2.0") & ", " & pkg("gcc", "12.0.0") & ", " &
      pkg("actionlint", "1.0.0")))
    check r.violations.len == 0

  test "an unselected instance is not held to the range":
    let r = checkRecipeLockConsistency(reproInputs(
      pkg("nim", "2.2.0") & ", " & pkg("nim", "1.6.0", "unselected")))
    check r.violations.len == 0

  test "an exact version against the producer's sourceRevision":
    let recipe = "package app:\n  uses:\n    \"lib ==1.4.0\"\n"
    var inputs = reproInputs("", recipe)
    inputs.reproLock = text("/w/app/repro.lock", reproLock([
      dep("app", ".", "https://example.invalid/app", ShaA),
      dep("lib", "../lib", "https://example.invalid/lib", ShaB)]))
    inputs.producerVersions = proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] =
      check depName == "lib"
      check depAbs == "/w/lib"
      (true, "/w/lib/repro.nim", reproRecipeVersions(
        "package lib:\n  versions:\n    \"1.4.0\":\n" &
        "      sourceRevision = \"refs/tags/v1.4.0\"\n"))
    var tagTarget = ShaC
    inputs.resolveRef = proc (depAbs, gitRef: string): string =
      check gitRef == "refs/tags/v1.4.0"
      tagTarget
    let r = checkRecipeLockConsistency(inputs)
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1:
      check h1[0].summary == "H1 (the lock satisfies the recipe): " &
        "/w/app/repro.nim:3 requires 'lib ==1.4.0', which " &
        "/w/lib/repro.nim:3 maps to sourceRevision refs/tags/v1.4.0 (" &
        ShaC & "), but /w/app/repro.lock resolves 'lib' at " & ShaB
    tagTarget = ShaB
    check checkRecipeLockConsistency(inputs).violations.len == 0
    tagTarget = ""
    let unresolved = checkRecipeLockConsistency(inputs)
    check unresolved.violations.len == 0
    check unresolved.notChecked.len == 1

  test "an exact version cut from another repository than the lock's is not compared":
    # The selector NAME finds the `repro.lock` entry `lib`; the producer's
    # `versions:` entry says 1.4.0 is cut from a DIFFERENT repository. One name
    # for two repositories is not a disagreement, so the revisions are not
    # compared — and the report says so rather than passing in silence.
    let recipe = "package app:\n  uses:\n    \"lib ==1.4.0\"\n"
    var inputs = reproInputs("", recipe)
    inputs.reproLock = text("/w/app/repro.lock", reproLock([
      dep("app", ".", "https://example.invalid/app", ShaA),
      dep("lib", "../lib", "https://example.invalid/lib", ShaB)]))
    var cutFrom = "https://example.invalid/other-lib"
    inputs.producerVersions = proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] =
      (true, "/w/lib/repro.nim", reproRecipeVersions(
        "package lib:\n  versions:\n    \"1.4.0\":\n" &
        "      sourceRevision = \"" & ShaC & "\"\n" &
        "      sourceRepository = \"" & cutFrom & "\"\n"))
    let r = checkRecipeLockConsistency(inputs)
    check r.violations.len == 0
    check r.notChecked == @["/w/app/repro.nim:3: 'lib ==1.4.0' — " &
      "/w/lib/repro.nim:3 cuts that version from example.invalid/other-lib, " &
      "but the repro.lock entry 'lib' fetches example.invalid/lib; one name " &
      "for two repositories is not compared"]
    # The same repository under another spelling IS compared, and the
    # revisions disagree: H1.
    cutFrom = "git+https://example.invalid/lib.git"
    let same = checkRecipeLockConsistency(inputs)
    check same.violationsOf(crH1).len == 1
    check same.notChecked.len == 0

  test "a resolved version the range grammar cannot read is listed, not refused or passed":
    let r = checkRecipeLockConsistency(reproInputs(
      pkg("nim", "not-a-version") & ", " & pkg("gcc", "12.0.0")))
    check r.violations.len == 0
    check ("/w/app/repro.nim:5: 'nim >=2.2 <3.0' — /w/app/repro.lock " &
      "resolves package 'nim' at version not-a-version, which is not a " &
      "version this check can compare with a range") in r.notChecked

  test "two recipes pinning one repository at different revisions is H2":
    var inputs = reprobuildInputs(ShaA)
    inputs.reproNim = text("/w/reprobuild/repro.nim",
      "package reprobuild:\n  uses:\n    \"nim-stackable-hooks ==0.3.0\"\n")
    inputs.producerVersions = proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] =
      (true, depAbs & "/repro.nim", reproRecipeVersions(
        "package nim_stackable_hooks:\n  versions:\n    \"0.3.0\":\n" &
        "      sourceRevision = \"" & ShaB & "\"\n"))
    let r = checkRecipeLockConsistency(inputs)
    # repro.lock resolves ShaA (agreeing with flake.lock), so the resolution
    # half of H2 passes; the repro.nim pin maps to ShaB, which is H1 on the
    # repro side AND an H2 conflict between the two recipes.
    let h2 = r.violationsOf(crH2)
    check h2.len == 1
    if h2.len == 1:
      check "no single revision satisfies both recipes" in h2[0].summary
      check "kind=constraint-conflict" in h2[0].evidence
    check r.violationsOf(crH1).len == 1

suite "H1: constraints under when / if / case arms (the issue of 2026-11-15)":
  # A lock is resolved for ONE platform and one variant assignment, and it
  # records both (`platform`, `variants`). The arm a `uses:` entry sits under
  # is therefore decided for that lock, and H1 holds the lock to every
  # constraint whose arm applies to it — the usual way to state a toolchain
  # floor is per platform.

  const PerPlatformFloor = "import repro_project_dsl\n\npackage app:\n" &
    "  uses:\n" &
    "    when defined(macosx):\n" &
    "      \"clang\"\n" &
    "    else:\n" &
    "      \"gcc >=12\"\n"

  proc armInputs(recipe, packages: string; platform = "amd64-linux";
      variants = ""): ConsistencyInputs =
    result.repoRoot = "/w/app"
    result.lockPathBase = "/w/app"
    result.reproNim = text("/w/app/repro.nim", recipe)
    result.reproLock = text("/w/app/repro.lock", reproLock([
      dep("app", ".", "https://example.invalid/app", ShaA)], packages,
      platform, variants))

  test "a per-platform floor the Linux lock breaks is H1, not a note":
    # The shape the issue observed: gcc 11 on Linux under `gcc >=12`.
    let r = checkRecipeLockConsistency(armInputs(PerPlatformFloor,
      pkg("gcc", "11.0.0")))
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1:
      check h1[0].summary == "H1 (the lock satisfies the recipe): " &
        "/w/app/repro.nim:8 requires 'gcc >=12' (uses:), but " &
        "/w/app/repro.lock resolves package 'gcc' at version 11.0.0, which " &
        "that range does not admit"
    check r.notChecked.len == 0

  test "the same floor satisfied passes, with nothing left unchecked":
    let r = checkRecipeLockConsistency(armInputs(PerPlatformFloor,
      pkg("gcc", "12.0.0")))
    check r.violations.len == 0
    check r.notChecked.len == 0

  test "an arm that does not apply to the lock's platform is not held to it":
    # A macOS lock is resolved without the `else:` arm.
    let r = checkRecipeLockConsistency(armInputs(PerPlatformFloor,
      pkg("gcc", "11.0.0") & ", " & pkg("clang", "15.0.0"), "arm64-macosx"))
    check r.violations.len == 0
    check r.notChecked.len == 0

  test "an arm the lock cannot decide is listed, naming the arm and why":
    let recipe = "package app:\n  uses:\n" &
      "    when defined(reproExperimental):\n" &
      "      \"gcc >=13\"\n" &
      "    when defined(linux) or defined(reproExperimental):\n" &
      "      \"nim >=2.2\"\n" &
      "    when defined(macosx) and defined(reproExperimental):\n" &
      "      \"clang >=99\"\n"
    let r = checkRecipeLockConsistency(armInputs(recipe,
      pkg("gcc", "12.0.0") & ", " & pkg("nim", "2.0.0") & ", " &
      pkg("clang", "1.0.0")))
    # `defined(linux) or …` is true on Linux whatever the define says, so the
    # nim floor is checked; `defined(macosx) and …` is false there, so the
    # clang floor does not apply. Only the define alone is undecidable.
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1: check h1[0].dependency == "nim"
    check r.notChecked == @["/w/app/repro.nim:4: 'gcc >=13' — under " &
      "`when defined(reproExperimental)` (line 3), a `when` whose " &
      "conditions do not depend only on the lock's platform (amd64-linux), " &
      "so whether it applies to this lock is not decidable without " &
      "compiling the recipe"]

  test "elif and else arms apply only when every earlier arm does not":
    let recipe = "package app:\n  uses:\n" &
      "    when defined(windows):\n" &
      "      \"msvc >=19\"\n" &
      "    elif defined(posix) and not defined(macosx):\n" &
      "      \"gcc >=12\"\n" &
      "    else:\n" &
      "      \"clang >=15\"\n"
    let packages = pkg("msvc", "1.0.0") & ", " & pkg("gcc", "11.0.0") &
      ", " & pkg("clang", "14.0.0")
    proc violated(platform: string): seq[string] =
      let r = checkRecipeLockConsistency(armInputs(recipe, packages,
        platform))
      check r.notChecked.len == 0
      for v in r.violationsOf(crH1): result.add(v.dependency)
    check violated("amd64-linux") == @["gcc"]
    check violated("arm64-macosx") == @["clang"]
    check violated("amd64-windows") == @["msvc"]
    check violated("amd64-freebsd") == @["gcc"]

  test "an arm written on one line with its entry is scanned and decided":
    let recipe = "package app:\n  uses:\n" &
      "    when defined(macosx): \"clang\"\n" &
      "    else: \"gcc >=12\"\n"
    let r = checkRecipeLockConsistency(armInputs(recipe,
      pkg("gcc", "11.0.0")))
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1: check h1[0].recipeLine == 4
    check r.notChecked.len == 0

  test "an if variant gate applies by the value the lock records":
    let recipe = "package app:\n  uses:\n" &
      "    if tls.value:\n" &
      "      \"openssl >=3\"\n" &
      "    else:\n" &
      "      \"libressl >=4\"\n"
    let packages = pkg("openssl", "1.1.0") & ", " & pkg("libressl", "3.0.0")
    proc violated(variants: string): seq[string] =
      let r = checkRecipeLockConsistency(armInputs(recipe, packages,
        variants = variants))
      for v in r.violationsOf(crH1): result.add(v.dependency)
    check violated("{ name = \"tls\", value = \"true\" }") == @["openssl"]
    check violated("{ name = \"tls\", value = \"false\" }") ==
      @["libressl"]
    # No value recorded: listed, never passed or refused.
    let r = checkRecipeLockConsistency(armInputs(recipe, packages))
    check r.violations.len == 0
    check r.notChecked.len == 2
    if r.notChecked.len == 2:
      check "a gate on variant 'tls', for which the lock records no value" in
        r.notChecked[0]

  test "a case variant gate, and the arms the DSL lowers ungated":
    let recipe = "package app:\n  uses:\n" &
      "    case compiler.value\n" &
      "    of \"gcc\":\n" &
      "      \"gcc >=12\"\n" &
      "      if lto.value:\n" &
      "        \"lld >=15\"\n" &
      "    of \"clang\":\n" &
      "      \"clang >=15\"\n" &
      "    of \"a\", \"b\":\n" &
      "      \"make >=4\"\n" &
      "    else:\n" &
      "      \"cmake >=3\"\n"
    let packages = pkg("gcc", "11.0.0") & ", " & pkg("clang", "14.0.0") &
      ", " & pkg("lld", "1.0.0") & ", " & pkg("make", "3.0.0") & ", " &
      pkg("cmake", "2.0.0")
    let r = checkRecipeLockConsistency(armInputs(recipe, packages,
      variants = "{ name = \"compiler\", value = \"gcc\" }"))
    var violated: seq[string]
    for v in r.violationsOf(crH1): violated.add(v.dependency)
    # gcc: its arm is selected. lld: an `if` nested in a gated arm is lowered
    # under the outer gate, so it applies with it (no `lto` value needed).
    # make, cmake: a multi-label `of` and a case `else` are lowered ungated.
    # clang: its arm is not selected.
    check violated == @["gcc", "lld", "make", "cmake"]
    check r.notChecked.len == 0

  test "an exact pin under an arm that applies is compared by H2":
    let recipe = "package app:\n  uses:\n" &
      "    when defined(linux):\n" &
      "      \"lib ==1.4.0\"\n"
    var inputs = armInputs(recipe, "")
    inputs.reproLock = text("/w/app/repro.lock", reproLock([
      dep("app", ".", "https://example.invalid/app", ShaA),
      dep("lib", "../lib", "https://example.invalid/lib", ShaB)]))
    inputs.producerVersions = proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] =
      (true, "/w/lib/repro.nim", reproRecipeVersions(
        "package lib:\n  versions:\n    \"1.4.0\":\n" &
        "      sourceRevision = \"" & ShaC & "\"\n"))
    let r = checkRecipeLockConsistency(inputs)
    let h1 = r.violationsOf(crH1)
    check h1.len == 1
    if h1.len == 1:
      check h1[0].pinnedInReproNim
      check h1[0].recipeLine == 4
    check r.notChecked.len == 0

suite "the commit-time re-pin verdict (H3, §16.4)":

  proc repinInputs(recipe: string; tagOf: proc (tag: string): string):
      ConsistencyInputs =
    ## `app` requires something of `lib`, whose `versions:` maps 1.0.0 and
    ## 2.0.0 to tags; ``tagOf`` says which commit each tag names.
    result.repoRoot = "/w/app"
    result.lockPathBase = "/w/app"
    result.reproNim = text("/w/app/repro.nim", recipe)
    result.producerVersions = proc (depName, depAbs: string):
        tuple[found: bool; file: string; entries: seq[ReproVersionEntry]] =
      (true, "/w/lib/repro.nim", reproRecipeVersions(
        "package lib:\n  versions:\n" &
        "    \"1.0.0\":\n      sourceRevision = \"refs/tags/v1\"\n" &
        "    \"2.0.0\":\n      sourceRevision = \"refs/tags/v2\"\n"))
    result.resolveRef = proc (depAbs, gitRef: string): string =
      tagOf(gitRef)

  proc tags(gitRef: string): string =
    if gitRef == "refs/tags/v1": ShaA
    elif gitRef == "refs/tags/v2": ShaB
    else: ""

  test "a range excludes a revision its producer maps outside it":
    let inputs = repinInputs(
      "package app:\n  uses:\n    \"lib >=1.0 <2\"\n", tags)
    let admitted = reproRepinVerdict(inputs, "lib", "/w/lib",
      "https://example.invalid/lib", ShaA)
    check admitted.exclusions.len == 0
    check admitted.exactPin == ""
    let excluded = reproRepinVerdict(inputs, "lib", "/w/lib",
      "https://example.invalid/lib", ShaB)
    check excluded.exclusions.len == 1
    if excluded.exclusions.len == 1:
      var e = excluded.exclusions[0]
      check e.kind == rckRange
      check e.observedVersion == "2.0.0"
      check e.recipeFile == "/w/app/repro.nim"
      check e.recipeLine == 3
      e.lockedRev = ShaA
      e.held = @["/w/app/repro.lock 'lib' stays at " & ShaA]
      let v = repinExclusionViolation(e)
      check v.rule == crH3
      check v.summary == "H3 (the commit-time re-pin moves lock " &
        "resolutions, never a recipe constraint): the sibling checkout " &
        "/w/lib is at " & ShaB & ", but /w/app/repro.nim:3 requires " &
        "'lib >=1.0 <2', which does not admit version 2.0.0 " &
        "(/w/lib/repro.nim:5 maps " & ShaB & " to it); the re-pin wrote " &
        "nothing for this repository in either lock (/w/app/repro.lock " &
        "'lib' stays at " & ShaA & ")"
      # Not overridden: the experiment remedy is to check out an admitted
      # revision, runnable as printed.
      check v.remedies.len == 2
      check ("`git -C /w/lib checkout " & ShaA & "`") in v.remedies[1]
      check "develop override" notin v.remedies[1]

  test "a revision no versions: entry maps is listed, not refused":
    let inputs = repinInputs(
      "package app:\n  uses:\n    \"lib >=1.0 <2\"\n", tags)
    let v = reproRepinVerdict(inputs, "lib", "/w/lib",
      "https://example.invalid/lib", ShaC)
    check v.exclusions.len == 0
    check v.notChecked == @["/w/app/repro.nim:3: 'lib >=1.0 <2' — no " &
      "versions: entry of /w/lib/repro.nim maps to " & ShaC & ", so " &
      "whether that range admits the checkout is not decidable"]

  test "an exact version reports its pin and excludes every other revision":
    let inputs = repinInputs(
      "package app:\n  uses:\n    \"lib ==1.0.0\"\n", tags)
    let at = reproRepinVerdict(inputs, "lib", "/w/lib",
      "https://example.invalid/lib", ShaA)
    check at.exactPin == ShaA
    check at.exactPinLine == 3
    check at.exclusions.len == 0
    let past = reproRepinVerdict(inputs, "lib", "/w/lib",
      "https://example.invalid/lib", ShaB)
    check past.exclusions.len == 1
    if past.exclusions.len == 1:
      var e = past.exclusions[0]
      check e.kind == rckExactVersion
      check e.pinnedRev == ShaA
      e.overridden = true
      e.overrideRepo = "lib"
      e.overrideFiles = @["/w/.repro/develop-overrides.toml"]
      let v = repinExclusionViolation(e)
      check v.remedies[0] == "If " & ShaB & " is the intended upgrade, " &
        "run `repro lock update lib --to " & ShaB & "`: it changes the " &
        "uses: entry at /w/app/repro.nim:3 to the version whose " &
        "sourceRevision is " & ShaB & " and moves both locks with it (it " &
        "refuses when no versions: entry of /w/lib/repro.nim maps " & ShaB &
        "; add that entry first); then commit again"
      # HL-11 M5: the experiment remedy names the runnable drop command.
      check v.remedies[1] == "If " & ShaB & " was a temporary experiment, " &
        "drop the develop override of 'lib': `repro develop --drop=lib` " &
        "removes its entry from /w/.repro/develop-overrides.toml and " &
        "leaves the checkout as it is, or check the sibling out at the " &
        "pinned revision: `git -C /w/lib checkout " & ShaA & "`; then " &
        "commit again"
      # With the workspace and the repo known, the command names both, so
      # it runs unchanged from wherever the refusal is printed.
      e.workspaceRoot = "/w"
      e.repoRoot = "/w/app"
      check ("drop the develop override of 'lib': `repro develop --drop=lib " &
        "--workspace-root=/w --project-root=/w/app` removes its entry from " &
        "/w/.repro/develop-overrides.toml and leaves the checkout as it " &
        "is, or check the sibling out at the pinned revision: `git -C " &
        "/w/lib checkout " & ShaA & "`; then commit again") in
        repinExclusionViolation(e).remedies[1]
    # A conditional entry with no lock to decide its arm is listed, never
    # applied.
    let condRecipe = "package app:\n  uses:\n" &
      "    when defined(macosx):\n      \"lib ==1.0.0\"\n"
    let cond = reproRepinVerdict(repinInputs(condRecipe, tags), "lib",
      "/w/lib", "https://example.invalid/lib", ShaB)
    check cond.exclusions.len == 0
    check cond.exactPin == ""
    check cond.notChecked.len == 1
    # With the lock, its arm is decided: on a macOS lock the pin applies and
    # excludes every other revision; on a Linux lock it does not apply.
    for (platform, applies) in [("arm64-macosx", true),
        ("amd64-linux", false)]:
      var inputs = repinInputs(condRecipe, tags)
      inputs.reproLock = text("/w/app/repro.lock", reproLock([
        dep("app", ".", "https://example.invalid/app", ShaA)], "",
        platform))
      let v = reproRepinVerdict(inputs, "lib", "/w/lib",
        "https://example.invalid/lib", ShaB)
      checkpoint(platform)
      check v.notChecked.len == 0
      check v.exclusions.len == (if applies: 1 else: 0)
      check v.exactPin == (if applies: ShaA else: "")

suite "the uses: text scan":

  test "block, inline, nested policy, conditional arms, comments, strings":
    let src = "package p:\n" &
      "  build:\n" &
      "    shell \"\"\"\n" &
      "uses:\n" &
      "  \"not-an-entry >=1\"\n" &
      "\"\"\"\n" &
      "  uses:\n" &
      "    # \"commented >=1\"\n" &
      "    \"a >=1\"\n" &
      "    linkPolicy:\n" &
      "      \"b ^2.1\"\n" &
      "    case compiler.value\n" &
      "    of \"gcc\":\n" &
      "      \"c ==3.0.0\"\n" &
      "    \"d\"\n" &
      "  nativeBuildDeps: \"e >=4\"\n" &
      "when defined(windows):\n" &
      "  uses: \"f >=5\"\n"
    let decls = scanReproUsesDeclarations(src, "r.nim")
    var got: seq[string]
    for d in decls:
      got.add($d.constraint.line & ":" & d.rawConstraint & ":" & d.blockHead &
        (if d.conditional: ":cond" else: ""))
    check got == @["9:a >=1:uses", "11:b ^2.1:uses",
      "14:c ==3.0.0:uses:cond", "15:d:uses", "16:e >=4:nativeBuildDeps",
      "18:f >=5:uses:cond"]

  test "each conditional entry carries the arms it is under":
    let src = "package p:\n" &
      "  uses:\n" &
      "    when defined(windows):\n" &
      "      \"a\"\n" &
      "    elif defined(linux):\n" &
      "      case cc.value\n" &
      "      of \"gcc\": \"b >=1\"\n" &
      "      else:\n" &
      "        \"c\"\n" &
      "    else: \"d\"\n" &
      "    \"e\"\n"
    let decls = scanReproUsesDeclarations(src, "r.nim")
    check decls.len == 5
    if decls.len == 5:
      check decls[0].guards.len == 1
      check decls[0].guards[0].kind == rgkWhen
      check decls[0].guards[0].arm == 0
      check decls[0].guards[0].conditions ==
        @["defined(windows)", "defined(linux)", ""]
      check decls[1].guards.len == 2
      check decls[1].guards[0].arm == 1
      check decls[1].guards[1].kind == rgkCase
      check decls[1].guards[1].subject == "cc.value"
      check decls[1].guards[1].keywords == @["of", "else"]
      check decls[1].guards[1].conditions == @["\"gcc\"", ""]
      check decls[1].guards[1].insideBlock
      check decls[2].guards[1].arm == 1
      check decls[3].guards[0].arm == 2
      check decls[3].guards[0].line == 10
      check not decls[4].conditional
      check decls[4].guards.len == 0

  test "a colon inside a character literal does not end the condition":
    # `':'` in the condition used to be read as the arm's colon, which left
    # the arm's entry outside any arm and checked it unconditionally.
    let src = "package p:\n" &
      "  uses:\n" &
      "    when defined(linux) and c == ':' and 1'u8 > 0:\n" &
      "      \"a >=1\"\n" &
      "    else:\n" &
      "      \"b >=1\"\n"
    let decls = scanReproUsesDeclarations(src, "r.nim")
    check decls.len == 2
    if decls.len == 2:
      check decls[0].conditional
      check decls[0].guards.len == 1
      if decls[0].guards.len == 1:
        check decls[0].guards[0].kind == rgkWhen
        check decls[0].guards[0].arm == 0
        check decls[0].guards[0].conditions ==
          @["defined(linux) and c == ':' and 1'u8 > 0", ""]
      check decls[1].guards.len == 1
      if decls[1].guards.len == 1:
        check decls[1].guards[0].arm == 1

  test "a when condition is decided as Nim decides it for the target":
    proc at(cond, platform: string): Tri =
      evalWhenCondition(cond, lockArmFacts(platform, []))
    check at("defined(linux)", "amd64-linux") == triTrue
    check at("defined(macosx)", "amd64-linux") == triFalse
    check at("defined(macosx)", "arm64-macosx") == triTrue
    check at("defined(osx)", "arm64-macosx") == triTrue
    # `macos` is classic Mac OS to Nim: false on macOS X.
    check at("defined(macos)", "arm64-macosx") == triFalse
    check at("defined(posix)", "arm64-macosx") == triTrue
    check at("defined(posix)", "amd64-windows") == triFalse
    check at("defined(windows)", "amd64-windows") == triTrue
    check at("defined(x86_64)", "amd64-linux") == triTrue
    check at("defined(amd64) or defined(arm64)", "arm64-macosx") == triTrue
    check at("not (defined(linux) and defined(amd64))", "amd64-linux") ==
      triFalse
    check at("not defined(macosx) and not defined(windows)",
      "amd64-linux") == triTrue
    check at("defined(macosx) or (defined(windows) and defined(arm64))",
      "arm64-windows") == triTrue
    check at("defined(cpu64) and defined(littleEndian)", "amd64-linux") ==
      triTrue
    check at("hostOS == \"linux\"", "amd64-linux") == triTrue
    check at("\"windows\" != hostOS", "amd64-linux") == triTrue
    # Not a platform symbol: a `-d:` define the lock does not record.
    check at("defined(aarch64)", "arm64-linux") == triUnknown
    check at("defined(release)", "amd64-linux") == triUnknown
    check at("defined(release) or defined(linux)", "amd64-linux") == triTrue
    check at("defined(release) and defined(macosx)", "amd64-linux") ==
      triFalse
    # Text outside the grammar, and a lock with no (or an unknown) platform.
    check at("hostIsMacos", "arm64-macosx") == triUnknown
    check at("defined(linux) and", "amd64-linux") == triUnknown
    check at("defined(linux)", "") == triUnknown
    check at("defined(linux)", "amd64-plan9") == triUnknown

suite "the sibling guidance line (Unified-Locking-And-Hooks.md §16.6)":

  test "the guidance line names the sibling, the pointer and the conversion":
    let v = ConsistencyViolation(rule: crH1, system: "flake",
      dependency: "lib-src", pinnedInFlake: "lib-src",
      summary: "H1 (the lock satisfies the recipe): x", remedies: @["r"])
    let expected = "Guidance: 'lib' is a workspace sibling (checked out at " &
      "/w/lib); the dependency guidelines suggest tracking a sibling " &
      "through the lock rather than an exact recipe pin (see your " &
      "organisation's dependency guidelines). To convert, in flake.nix, " &
      "replace the exact revision in input 'lib-src''s url with a branch " &
      "reference; then run `repro lock update lib-src --repo-root=/w/app`."
    check siblingGuidanceLine(v, "lib", "/w/lib", "/w/app", "") == expected
    # A configured pointer replaces the generic one, and nothing else.
    check siblingGuidanceLine(v, "lib", "/w/lib", "/w/app",
      "  https://example.invalid/g  ") == expected.replace(
        "see your organisation's dependency guidelines",
        "see https://example.invalid/g")
    # The value is display text: a backtick (which would forge a command
    # span) and a line break (which would forge a refusal line) are dropped.
    check dependencyGuidelinesPointer("https://g.invalid/`rm -rf x`\nH1 (") ==
      "see https://g.invalid/rm -rf xH1 ("
    check dependencyGuidelinesPointer("\t\n `` ") ==
      "see your organisation's dependency guidelines"
    # A repro.nim pin, and a repository both recipes pin.
    var r = ConsistencyViolation(rule: crH2, system: "both",
      dependency: "lib", pinnedInReproNim: true)
    let head = "Guidance: 'lib' is a workspace sibling (checked out at " &
      "/w/lib); the dependency guidelines suggest tracking a sibling " &
      "through the lock rather than an exact recipe pin (see your " &
      "organisation's dependency guidelines). "
    check siblingGuidanceLine(r, "lib", "/w/lib", "/w/app", "") == head &
      "To convert, in repro.nim, replace the exact uses: version with " &
      "a range, or name the dependency without one; then run `repro lock " &
      "update lib --repo-root=/w/app`."
    r.pinnedInFlake = "lib-src"
    check siblingGuidanceLine(r, "lib", "/w/lib", "/w/app", "") == head &
      "To convert, in flake.nix, replace the exact revision in input " &
      "'lib-src''s url with a branch reference; in repro.nim, replace the " &
      "exact uses: version with a range, or name the dependency without " &
      "one; then run `repro lock update lib --repo-root=/w/app`."

  test "no exact pin, no guidance line; the line renders after its paragraph":
    var v = ConsistencyViolation(rule: crH1, system: "repro",
      dependency: "libfoo",
      summary: "H1 (the lock satisfies the recipe): a range", remedies: @["r"])
    check not v.recipePinsExactly
    check siblingGuidanceLine(v, "lib", "/w/lib", "/w/app", "") == ""
    check renderConsistencyRefusal([v]) ==
      @["H1 (the lock satisfies the recipe): a range. (1) r."]
    v.guidance = "Guidance: g"
    check renderConsistencyRefusal([v]) ==
      @["H1 (the lock satisfies the recipe): a range. (1) r.", "Guidance: g"]

  test "which violations carry an exact pin":
    # An exact flake pin locked elsewhere: H1 naming the pinning input.
    let flakeNix = "{\n  inputs = {\n    lib-src.url = " &
      "\"github:o/lib/" & ShaA & "\";\n  };\n}\n"
    let r = checkRecipeLockConsistency(ConsistencyInputs(repoRoot: "/w/app",
      flakeNix: text("/w/app/flake.nix", flakeNix),
      flakeLock: text("/w/app/flake.lock",
        flakeLock([("lib-src", githubNode("o", "lib", ShaB))]))))
    check r.violations.len == 1
    if r.violations.len == 1:
      check r.violations[0].pinnedInFlake == "lib-src"
      check not r.violations[0].pinnedInReproNim
      check r.violations[0].guidance == ""
    # original.rev against locked.rev with NO recipe pin: nothing to convert.
    let floating = "{\n  inputs = {\n    lib-src.url = \"github:o/lib\";\n" &
      "  };\n}\n"
    let f = checkRecipeLockConsistency(ConsistencyInputs(repoRoot: "/w/app",
      flakeNix: text("/w/app/flake.nix", floating),
      flakeLock: text("/w/app/flake.lock",
        flakeLock([("lib-src", githubNode("o", "lib", ShaB, ShaA))]))))
    check f.violations.len == 1
    if f.violations.len == 1:
      check not f.violations[0].recipePinsExactly
    # An H3 range exclusion has no exact pin to convert; an exact one does.
    let range = repinExclusionViolation(RepinConstraintExclusion(
      kind: rckRange, dependency: "lib", checkout: "/w/lib",
      observed: ShaB, constraintText: "lib >=1 <2", observedVersion: "2.0.0",
      recipeFile: "/w/app/repro.nim", recipeLine: 5))
    check not range.recipePinsExactly
    check range.checkout == "/w/lib"
    let exact = repinExclusionViolation(RepinConstraintExclusion(
      kind: rckFlakeRev, dependency: "lib-src", checkout: "/w/lib",
      observed: ShaB, pinnedRev: ShaA, recipeFile: "/w/app/flake.nix",
      recipeLine: 3))
    check exact.pinnedInFlake == "lib-src"
    let version = repinExclusionViolation(RepinConstraintExclusion(
      kind: rckExactVersion, dependency: "lib", checkout: "/w/lib",
      observed: ShaB, pinnedRev: ShaA, constraintText: "lib ==1.0.0",
      recipeFile: "/w/app/repro.nim", recipeLine: 5))
    check version.pinnedInReproNim and version.pinnedInFlake == ""
