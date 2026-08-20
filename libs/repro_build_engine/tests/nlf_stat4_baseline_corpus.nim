## The NLF-STAT-4 baseline corpus: one graph, every engine edge kind.
##
## Named-Lock-Files NLF-M4. Corpus case **NLF-STAT-4** ("a workspace declaring
## nothing is unchanged") is the campaign's migration gate. Per
## `Named-Lock-Files-Test-Corpus.md` §6 it is "the one case in the corpus that
## must run against **both** the pre-change and post-change implementation, so
## it needs recorded baseline fingerprints as a fixture".
##
## This module is that fixture's GENERATOR, and it is deliberately not named
## `t_*` / `test_*` so `scripts/generate_test_edges.nim` does not register it as
## a test binary of its own. It builds a graph that stands in for "an existing
## workspace with no lock-file declarations": every `BuildActionKind` the engine
## knows about is represented, constructed through the engine's own public
## constructors (`action` / `builtinAction`) and through direct `BuildAction`
## object construction — because the engine has all three construction shapes
## and a migration gate that covered only one of them would miss exactly the
## edge kind nobody thought to exercise.
##
## Test-double policy: NO mocks, doubles, or fakes. The actions are real
## `BuildAction` values from the real engine constructors and the recorded
## fingerprint is the real `weakFingerprint` the action cache keys on
## (`repro_local_store.ActionCache` looks up by exactly this digest).
##
## WHAT IS RECORDED, AND WHY TWO COLUMNS.
##
##   * `fingerprint` — the action's `weakFingerprint`, lowercase hex. This is
##     the value NLF-STAT-4 requires to be byte-identical across the campaign.
##     Measured caveat, stated because it bounds what this column can catch:
##     today `weakFingerprint` is `blake3DomainDigest(id)` — a function of the
##     action *id* alone — so it moves only if id derivation changes or if
##     something is newly mixed into the fingerprint. Mixing the governing lock
##     identity into it is precisely the change NLF-STAT-4 forbids for the
##     default path, so this column is the direct gate on that.
##   * `material` — a digest over the action's pre-NLF-M4 observable content:
##     kind, id, argv, cwd, env, inputs, outputs, deps, pool and cacheable. It
##     exists because the fingerprint column alone would be nearly vacuous
##     against a change that alters what an action DOES while leaving its id
##     alone — the silent direction. The field list is frozen as of the
##     baseline and deliberately excludes `governingLockIdentity`, which is new
##     by construction; NLF-STAT-4 asks whether the DEFAULT PATH is unchanged,
##     not whether a new carrier field exists.

import std/[algorithm, strutils]

import repro_build_engine
import repro_hash

const BaselineFixtureRelPath* =
  "fixtures/nlf_stat4_baseline_fingerprints.tsv"
  ## Relative to this module's directory.

proc hex(digest: ContentDigest): string =
  result = newStringOfCap(digest.bytes.len * 2)
  const digits = "0123456789abcdef"
  for b in digest.bytes:
    result.add(digits[int(b shr 4)])
    result.add(digits[int(b and 0x0F'u8)])

proc canonicalMaterial*(a: BuildAction): string =
  ## The canonical rendering of an action's pre-NLF-M4 observable content.
  ## Field order is fixed and every sequence is rendered with an explicit
  ## length prefix, so no two distinct actions can render to one string by
  ## concatenation ambiguity. `env` is sorted because the engine does not
  ## promise an order for it; every other sequence is positional and its
  ## order is semantic.
  proc part(label: string; items: openArray[string]): string =
    result = label & "[" & $items.len & "]"
    for item in items:
      result.add("\x1f" & item)
    result.add("\x1e")
  result = "kind=" & $a.kind & "\x1e"
  result.add("id=" & a.id & "\x1e")
  result.add(part("argv", a.argv))
  result.add("cwd=" & a.cwd & "\x1e")
  var env = a.env
  env.sort()
  result.add(part("env", env))
  result.add(part("inputs", a.inputs))
  result.add(part("outputs", a.outputs))
  result.add(part("deps", a.deps))
  result.add("pool=" & a.pool & "\x1e")
  result.add("cacheable=" & (if a.cacheable: "1" else: "0") & "\x1e")

proc baselineRow*(a: BuildAction): string =
  ## One TSV row: `id<TAB>kind<TAB>fingerprint<TAB>material`.
  a.id & "\t" & $a.kind & "\t" & hex(a.weakFingerprint) & "\t" &
    hex(weakFingerprintFromText(canonicalMaterial(a)))

proc baselineCorpusActions*(): seq[BuildAction] =
  ## The corpus graph. Every `BuildActionKind` appears at least once, and the
  ## three construction shapes the engine offers are all exercised:
  ## `action()` for process edges, `builtinAction()` for the built-ins, and
  ## direct `BuildAction(...)` object construction for the kinds whose callers
  ## build them by hand today (`bakWorkspaceVcs`,
  ## `bakBinaryCacheSubstitute`, `bakForeignProvision`).
  result = @[]

  # --- process edges, via `action()` ------------------------------------
  result.add(action("stat4/compile-main",
    ["/usr/bin/cc", "-c", "src/main.c", "-o", "build/main.o"],
    cwd = "/workspace",
    inputs = ["src/main.c"],
    outputs = ["build/main.o"],
    cacheable = true,
    env = ["CC=/usr/bin/cc", "LANG=C"]))
  result.add(action("stat4/link-app",
    ["/usr/bin/cc", "build/main.o", "-o", "build/app"],
    cwd = "/workspace",
    deps = ["stat4/compile-main"],
    inputs = ["build/main.o"],
    outputs = ["build/app"],
    pool = "link",
    poolUnits = 2'u32,
    cacheable = true))
  result.add(action("stat4/run-tests",
    ["build/app", "--selftest"],
    cwd = "/workspace",
    deps = ["stat4/link-app"],
    inputs = ["build/app"],
    outputs = ["build/tests.stamp"],
    cacheable = false))

  # --- built-in edges, via `builtinAction()` ----------------------------
  result.add(builtinAction(bakEnsureDir, "stat4/ensure-dist",
    outputs = ["dist"]))
  result.add(builtinAction(bakCopyFile, "stat4/copy-app",
    deps = ["stat4/link-app", "stat4/ensure-dist"],
    inputs = ["build/app"],
    outputs = ["dist/app"]))
  result.add(builtinAction(bakWriteText, "stat4/write-manifest",
    outputs = ["dist/manifest.txt"],
    text = "app\n"))
  result.add(builtinAction(bakStamp, "stat4/stamp-dist",
    deps = ["stat4/copy-app", "stat4/write-manifest"],
    outputs = ["dist/.stamp"]))
  result.add(builtinAction(bakPreserveTree, "stat4/preserve-src",
    inputs = ["src"],
    outputs = ["dist/src.preserved"]))
  result.add(builtinAction(bakEnsureLine, "stat4/ensure-line",
    outputs = ["dist/profile"],
    text = "export PATH=/opt/bin:$PATH"))
  result.add(builtinAction(bakEnsureSnippet, "stat4/ensure-snippet",
    outputs = ["dist/rc"],
    text = "# managed by repro\n",
    entries = ["begin", "end"]))

  # --- kinds constructed by hand today ----------------------------------
  result.add(BuildAction(
    kind: bakWorkspaceVcs,
    id: "stat4/vcs-clone",
    outputs: @["checkout/.git"],
    cacheable: false,
    weakFingerprint: weakFingerprintFromText("stat4/vcs-clone"),
    builtinText: "clone\thttps://example.invalid/repo.git\tcheckout"))
  result.add(BuildAction(
    kind: bakBinaryCacheSubstitute,
    id: "stat4/substitute-zlib",
    outputs: @["store/zlib.stamp"],
    cacheable: true,
    weakFingerprint: weakFingerprintFromText("stat4/substitute-zlib"),
    builtinText: "0123456789abcdef\thttps://cache.example.invalid"))
  result.add(BuildAction(
    kind: bakForeignProvision,
    id: "stat4/provision-nix",
    outputs: @["store/foreign.stamp"],
    cacheable: true,
    weakFingerprint: weakFingerprintFromText("stat4/provision-nix"),
    builtinText: "nix\t/nix/store/aaaa-foo"))

proc baselineCorpusText*(): string =
  ## The whole fixture body: a header line, then one row per action in
  ## declaration order (which is the graph's own order — not sorted, so a
  ## reordering of the corpus is itself caught).
  result = "# NLF-STAT-4 baseline — id\tkind\tfingerprint\tmaterial\n"
  for a in baselineCorpusActions():
    result.add(baselineRow(a) & "\n")

proc assertEveryEdgeKindCovered*(): string =
  ## Returns "" when every `BuildActionKind` appears in the corpus, or a
  ## diagnostic naming the missing kinds. A migration gate that silently
  ## stopped covering a kind would be the §7.2 failure shape in miniature.
  var seen: set[BuildActionKind] = {}
  for a in baselineCorpusActions():
    seen.incl(a.kind)
  var missing: seq[string] = @[]
  for k in BuildActionKind:
    if k notin seen:
      missing.add($k)
  if missing.len == 0: "" else: "uncovered edge kinds: " & missing.join(", ")
