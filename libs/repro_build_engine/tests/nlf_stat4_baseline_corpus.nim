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

const CorpusPlatform* = "amd64-linux"
  ## The platform the corpus's empty solved graph is taken FOR.
  ##
  ## Pinned rather than read from the host, and NLF-M7 is what forced the
  ## question. A lock identity is content-derived and the platform is part of
  ## that content (`repro_lock/identity.nim` §"What IS in the key beyond
  ## §6.2's four components"), so once §7's keying became effective the
  ## fingerprint column below would have become HOST-DEPENDENT — recorded on
  ## `amd64-linux` and failing on `arm64-darwin` for a reason that has nothing
  ## to do with the property under test.
  ##
  ## Pinning it is honest rather than a workaround: the corpus stands in for
  ## "an existing workspace with no lock-file declarations", and which machine
  ## that workspace is read on is not one of its facts. The value is a real
  ## recompute over the empty graph for a NAMED platform, which is exactly
  ## what `emptySolvedGraphIdentity` is for, and it is the same primitive
  ## `repro_lock_gen` uses for a generation request that carries its own
  ## platform.

let CorpusLockIdentity = emptySolvedGraphIdentity(CorpusPlatform)
  ## `let`, not `const`: the identity is a real BLAKE3 recompute and the Nim
  ## VM cannot call the C hash at compile time.
  ##
  ## Named-Lock-Files §7.2 — the corpus stands in for "a workspace with no
  ## lock-file declarations", so its edges are governed by the empty solved
  ## graph.
  ##
  ## **NLF-M7 changed what this value does.** Through NLF-M4-M6 it was
  ## deliberately NOT part of `weakFingerprint`: the identity was carried and
  ## unused, because NLF-STAT-4 required byte-identical fingerprints while
  ## §7's keying was not yet in force. NLF-M7 makes the keying effective, so
  ## every row's `fingerprint` column below moves exactly once, and the
  ## `material` column — which is frozen at the pre-NLF-M4 field list and
  ## still excludes `governingLockIdentity` — does not move at all. That
  ## split is what makes the diff explainable: a fingerprint change with an
  ## unchanged material digest is the keying landing, and a material change
  ## would be something else entirely.

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
  ##
  ## The hand-constructed three compose their fingerprint with
  ## `weakFingerprintFor`, which is `weakFingerprintFromText` keyed on the
  ## governing lock — the same composition the two constructors apply
  ## internally. §7.2's structural check reaches an object literal through
  ## `{.requiresInit.}`, but a constructor's BODY cannot, so the third shape
  ## is exactly where design A could be applied incompletely and is the shape
  ## this corpus exists to keep covered.
  result = @[]

  # --- process edges, via `action()` ------------------------------------
  result.add(action("stat4/compile-main",
    ["/usr/bin/cc", "-c", "src/main.c", "-o", "build/main.o"],
    governingLockIdentity = CorpusLockIdentity,
    cwd = "/workspace",
    inputs = ["src/main.c"],
    outputs = ["build/main.o"],
    cacheable = true,
    env = ["CC=/usr/bin/cc", "LANG=C"]))
  result.add(action("stat4/link-app",
    ["/usr/bin/cc", "build/main.o", "-o", "build/app"],
    governingLockIdentity = CorpusLockIdentity,
    cwd = "/workspace",
    deps = ["stat4/compile-main"],
    inputs = ["build/main.o"],
    outputs = ["build/app"],
    pool = "link",
    poolUnits = 2'u32,
    cacheable = true))
  result.add(action("stat4/run-tests",
    ["build/app", "--selftest"],
    governingLockIdentity = CorpusLockIdentity,
    cwd = "/workspace",
    deps = ["stat4/link-app"],
    inputs = ["build/app"],
    outputs = ["build/tests.stamp"],
    cacheable = false))

  # --- built-in edges, via `builtinAction()` ----------------------------
  result.add(builtinAction(bakEnsureDir, "stat4/ensure-dist",
    governingLockIdentity = CorpusLockIdentity,
    outputs = ["dist"]))
  result.add(builtinAction(bakCopyFile, "stat4/copy-app",
    governingLockIdentity = CorpusLockIdentity,
    deps = ["stat4/link-app", "stat4/ensure-dist"],
    inputs = ["build/app"],
    outputs = ["dist/app"]))
  result.add(builtinAction(bakWriteText, "stat4/write-manifest",
    governingLockIdentity = CorpusLockIdentity,
    outputs = ["dist/manifest.txt"],
    text = "app\n"))
  result.add(builtinAction(bakStamp, "stat4/stamp-dist",
    governingLockIdentity = CorpusLockIdentity,
    deps = ["stat4/copy-app", "stat4/write-manifest"],
    outputs = ["dist/.stamp"]))
  result.add(builtinAction(bakPreserveTree, "stat4/preserve-src",
    governingLockIdentity = CorpusLockIdentity,
    inputs = ["src"],
    outputs = ["dist/src.preserved"]))
  result.add(builtinAction(bakEnsureLine, "stat4/ensure-line",
    governingLockIdentity = CorpusLockIdentity,
    outputs = ["dist/profile"],
    text = "export PATH=/opt/bin:$PATH"))
  result.add(builtinAction(bakEnsureSnippet, "stat4/ensure-snippet",
    governingLockIdentity = CorpusLockIdentity,
    outputs = ["dist/rc"],
    text = "# managed by repro\n",
    entries = ["begin", "end"]))

  # --- kinds constructed by hand today ----------------------------------
  result.add(BuildAction(
    governingLockIdentity: CorpusLockIdentity,
    kind: bakWorkspaceVcs,
    id: "stat4/vcs-clone",
    outputs: @["checkout/.git"],
    cacheable: false,
    weakFingerprint: weakFingerprintFor("stat4/vcs-clone", CorpusLockIdentity),
    builtinText: "clone\thttps://example.invalid/repo.git\tcheckout"))
  result.add(BuildAction(
    governingLockIdentity: CorpusLockIdentity,
    kind: bakBinaryCacheSubstitute,
    id: "stat4/substitute-zlib",
    outputs: @["store/zlib.stamp"],
    cacheable: true,
    weakFingerprint: weakFingerprintFor("stat4/substitute-zlib", CorpusLockIdentity),
    builtinText: "0123456789abcdef\thttps://cache.example.invalid"))
  result.add(BuildAction(
    governingLockIdentity: CorpusLockIdentity,
    kind: bakForeignProvision,
    id: "stat4/provision-nix",
    outputs: @["store/foreign.stamp"],
    cacheable: true,
    weakFingerprint: weakFingerprintFor("stat4/provision-nix", CorpusLockIdentity),
    builtinText: "nix\t/nix/store/aaaa-foo"))

proc postBaselineCorpusActions*(): seq[BuildAction] =
  ## Edge kinds introduced AFTER the NLF-STAT-4 baseline was recorded.
  ##
  ## Kept apart from `baselineCorpusActions` on purpose, and the split is the
  ## whole point rather than a filing convenience. NLF-STAT-4's property is
  ## that "an existing workspace with no lock-file declarations" has
  ## byte-identical fingerprints across the campaign. An edge kind that did
  ## not exist when the baseline was recorded appears in NO existing
  ## workspace, so appending it to the recorded fixture would not be measuring
  ## that property — it would be relaxing the fixture's "no row was added"
  ## check, which is one of the two directions the gate catches.
  ##
  ## The coverage obligation is separate and is NOT relaxed:
  ## `assertEveryEdgeKindCovered` reads BOTH lists, so a kind added without a
  ## corpus entry still fails, and `t_fingerprint_audit_every_action_has_lock_identity`
  ## audits both so a new kind cannot quietly opt out of §7.2 either.
  ##
  ## NLF-M5 (`bakMetadataFetch` / `bakSolveLock`): both are constructed
  ## through `builtinAction`, and the fetch edge carries the `netFetch`
  ## network mode plus its tracked destination — the declaration
  ## `Sandbox-And-Monitoring.md` §"The Network Dimension" requires to be
  ## visible in the graph before the action runs.
  result = @[]
  result.add(builtinAction(bakMetadataFetch, "stat4/fetch-libfoo-versions",
    governingLockIdentity = CorpusLockIdentity,
    outputs = ["generation/libfoo.versions"],
    text = "http://index.example.invalid/metadata/libfoo.versions",
    networkMode = netFetch,
    netDestinations = ["http://index.example.invalid/metadata/"]))
  result.add(builtinAction(bakSolveLock, "stat4/solve-lock",
    governingLockIdentity = CorpusLockIdentity,
    deps = ["stat4/fetch-libfoo-versions"],
    inputs = ["generation/libfoo.versions"],
    outputs = ["generation/repro.lock"]))

proc everyEdgeKindActions*(): seq[BuildAction] =
  ## The baseline corpus plus every post-baseline kind: the graph the §7.2
  ## whole-graph audit runs against, and the one coverage is measured over.
  result = baselineCorpusActions()
  result.add(postBaselineCorpusActions())

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
  ##
  ## Reads the UNION of the frozen baseline and the post-baseline kinds, so
  ## the fixture can stay frozen without the coverage obligation narrowing.
  var seen: set[BuildActionKind] = {}
  for a in everyEdgeKindActions():
    seen.incl(a.kind)
  var missing: seq[string] = @[]
  for k in BuildActionKind:
    if k notin seen:
      missing.add($k)
  if missing.len == 0: "" else: "uncovered edge kinds: " & missing.join(", ")
