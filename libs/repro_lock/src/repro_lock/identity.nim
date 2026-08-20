## Lock identity over the canonical solved graph, and the provenance side
## table — `Named-Lock-Files.md` §6.
##
## Named-Lock-Files NLF-M4. Two things live here and they are deliberately
## kept apart:
##
##   * **`lockIdentityOf`** — §6.2's key. A hash of the canonical SOLVED
##     GRAPH: per package instance the package name, the pinned version, the
##     resolved feature/variant assignment and the source identity.
##   * **`LockProvenance`** — §6.3's side table. Lock identity → the SET of
##     lock-file names that resolved to it, read by diagnostics and never
##     mixed into a key.
##
## ## Why this module has no solver dependency
##
## `repro_lock.nim` imports `repro_solver`, which loads `libclingo` through a
## `{.dynlib.}` FFI at module-init time. The build engine must be able to
## carry a governing lock identity on every action without every engine binary
## acquiring a clingo runtime dependency, so the identity primitives live in
## this leaf module (only `std` + `repro_multihash`) and `repro_lock.nim`
## imports and re-exports it. The direction of the dependency is the whole
## point; do not reverse it.
##
## ## The name cannot enter the key, and that is enforced by the type
##
## §6.2: "The lock file name is a **handle** … and MUST NOT participate in any
## cache key." `lockIdentityOf` takes a `CanonicalSolvedGraph`, which has no
## name field of any kind. There is no argument through which a name could be
## passed, so name-in-key is a compile error rather than a convention. The
## §6.4 position — name in the key — was considered and rejected by the owner
## on 2026-08-18; this signature is that rejection made structural.
##
## ## What is deliberately NOT in the key
##
## **The solver-inputs digest.** A committed lock carries `inputs_digest`, a
## digest over the rendered solver INPUTS — the constraint set, the *question*.
## Keying on it is precisely the formula §6.2 was corrected away from on
## 2026-08-18: "Two solver versions, or one solver under a different
## configuration, can produce **different solved graphs from identical
## constraints** … Under constraint-set keying those two graphs **collide on
## one key** and serve each other's artifacts." Corpus case NLF-ID-7 is the
## regression for exactly that, and it is discriminating only because
## `inputsDigest` is excluded here.
##
## **The optimality flag.** `optimal` is a report about the SOLVE (did the
## search prove optimality before its bound), not a fact about the answer. Two
## identical graphs, one reached under a proof of optimality and one not, are
## the same graph and build the same artifacts.
##
## ## What IS in the key beyond §6.2's four components
##
## **The platform fact.** §6.2's formula enumerates four per-package-instance
## components and says nothing about the graph as a whole. The platform is
## nevertheless part of what the solved graph IS: the same pins solved for
## `amd64-linux` and for `arm64-darwin` are two different answers, and omitting
## the platform would collapse them onto one key and serve one platform's
## artifacts to the other. This is content, not a label, so it is admitted
## under §6.2's own rule — "Anything that legitimately distinguishes two lock
## files must be something the key already captures." Flagged here rather than
## added silently, because §0 asks that additions to a specified formula be
## legible at the point of the addition.

import std/[algorithm, tables]

import repro_multihash

type
  SolvedVariantAssignment* = object
    ## One resolved feature/variant assignment. `name` is the variant's
    ## declared name; `value` is the value the solver picked.
    name*: string
    value*: string

  SolvedPackageInstance* = object
    ## One package instance in the solved graph — §6.2's unit of the formula.
    name*: string
      ## The package name. Unique within a solved graph: the solver produces
      ## "one concrete package instance per solved package node"
      ## (`Locking-And-Solver.md` §"Solver Outputs").
    version*: string
      ## The pinned version.
    sourceIdentity*: string
      ## Repository / revision / store hash — whatever identifies WHERE the
      ## instance's content comes from.
    variants*: seq[SolvedVariantAssignment]
      ## The instance's resolved feature/variant assignment. §6.1: a key that
      ## omitted feature selections would let "two genuinely different lock
      ## files collide".

  CanonicalSolvedGraph* = object
    ## The solved graph, in the shape §6.2 hashes. Constructed from a lock or
    ## from a live solution by `repro_lock`; canonicalised (sorted, framed) by
    ## `lockIdentityOf` rather than by the caller, so no caller can produce a
    ## different key for the same graph by handing the fields over in a
    ## different order — the §1.3 hazard, closed here by construction.
    platform*: string
    packages*: seq[SolvedPackageInstance]
    graphVariants*: seq[SolvedVariantAssignment]
      ## Variant assignments the solved graph records at graph scope rather
      ## than against a package instance.
      ##
      ## **[MEASURED]** Today's `UnifiedSolution` carries variants in exactly
      ## one place — a flat `Table[string, string]` over the whole solve — so
      ## a lock read off disk populates this field and leaves every
      ## `SolvedPackageInstance.variants` empty. §6.1 requires the feature
      ## selections to be in the key and this is where they enter; the
      ## per-instance field exists because `Configurable-System.md`
      ## §"Solver-Phase Resolution" specifies a value "per resolved package
      ## instance" and the solved graph will eventually say so. Both are
      ## hashed, so populating the per-instance field later is additive.

  LockIdentity* = distinct string
    ## A lock file's content-derived identity: a self-describing multihash
    ## (`blake3:<hex>`). The zero value is the empty string and is INVALID —
    ## §7.2 requires that "an action constructed without a governing lock
    ## identity is a build-time error, not a default", so nothing in this
    ## module ever hands back an empty identity and `isValid` is what the
    ## engine's whole-graph audit asserts.

  LockProvenance* = object
    ## §6.3's side table: lock identity → the SET of lock-file names that
    ## resolved to it.
    ##
    ## The deliberate improvement on the precedent is the set. BuildXL's
    ## `m_qualifierToFriendlyQualifierName.TryAdd(qualifierId, name)`
    ## (`QualifierTable.cs:148-153`) is lossy — when two differently-named
    ## qualifiers intern to one id the second name is silently discarded.
    ## §6.3: "Reprobuild should instead map one identity → the set of
    ## lock-file names that resolved to it, because that set is exactly the
    ## information §8 wants to surface."
    ##
    ## Nothing here composes an identity with a name. That is the §6.3
    ## requirement — "maintained alongside the cache and never mixed into any
    ## key" — and the module exposes no operation that would let a caller do
    ## it by accident.
    byIdentity: Table[string, seq[string]]

proc currentPlatformId*(): string =
  ## The platform fact recorded in the lock, checked by `repro lock validate`,
  ## and hashed into a lock identity. MO-1 uses the build host's `cpu-os`
  ## identity (e.g. `amd64-linux`).
  ##
  ## Defined in this leaf module rather than in `repro_lock.nim` so that every
  ## consumer of a lock identity — including the build engine, which must not
  ## import the solver (see this module's header) — reads the SAME definition.
  ## `repro_lock` re-exports it, so its existing callers are unaffected.
  hostCPU & "-" & hostOS

proc `$`*(id: LockIdentity): string {.borrow.}
proc `==`*(a, b: LockIdentity): bool {.borrow.}

proc isValid*(id: LockIdentity): bool =
  ## A lock identity is valid when it is a well-formed self-describing
  ## multihash. The empty string — the `distinct string` zero value, and
  ## therefore what an un-set field holds — is not.
  isWellFormedMultihash(string(id))

proc sortedVariants(items: seq[SolvedVariantAssignment]):
    seq[SolvedVariantAssignment] =
  result = items
  result.sort(proc(a, b: SolvedVariantAssignment): int = cmp(a.name, b.name))

proc packageDigest(p: SolvedPackageInstance): string =
  ## The canonical digest of one package instance's content. Nested rather
  ## than flattened into the parent's path space on purpose: a flat encoding
  ## would let a package named `libfoo/variant/x` and a package `libfoo` with
  ## a variant named `x` render to the same path, which is the concatenation
  ## ambiguity `narStyleTreeSerialization` exists to prevent and which a
  ## hand-built path would reintroduce one level up.
  var entries: seq[tuple[path: string, content: string]] = @[
    (path: "version", content: p.version),
    (path: "source", content: p.sourceIdentity)]
  for v in sortedVariants(p.variants):
    entries.add((path: "variant/" & v.name, content: v.value))
  narStyleTreeMultihash(entries)

proc lockIdentityOf*(graph: CanonicalSolvedGraph): LockIdentity =
  ## §6.2's key: `lockIdentity = hash(canonical solved graph)`.
  ##
  ## Order-independent by construction — `narStyleTreeSerialization` sorts by
  ## path and length-frames every field, so two renderings of one graph are
  ## byte-identical regardless of the order the caller assembled the seqs in.
  ## `Named-Lock-Files.md` §1.3 makes that a hard prerequisite: "An identity
  ## scheme built on a non-canonical rendering does not fail loudly. It
  ## produces two different keys for one lock file — a silent cache miss and a
  ## duplicated build."
  var entries: seq[tuple[path: string, content: string]] = @[
    (path: "meta/platform", content: graph.platform)]
  for v in sortedVariants(graph.graphVariants):
    entries.add((path: "variant/" & v.name, content: v.value))
  for p in graph.packages:
    entries.add((path: "package/" & p.name, content: packageDigest(p)))
  LockIdentity(narStyleTreeMultihash(entries))

proc emptySolvedGraphIdentity*(platform: string): LockIdentity =
  ## The identity of the solved graph with no package instances and no
  ## variant assignments, for `platform`.
  ##
  ## This is a genuine recompute over an empty graph, not a sentinel: it is
  ## what an edge whose identity depends on no solved package instance — a
  ## workspace `git clone`, a dev-environment materialisation — is honestly
  ## governed by, and it changes with the platform like any other identity.
  ## It is NOT a default: §7.2 forbids one, so every call site that uses it
  ## must say so in its own source rather than inheriting it from a parameter
  ## default.
  lockIdentityOf(CanonicalSolvedGraph(
    platform: platform, packages: @[], graphVariants: @[]))

proc lockIdentityOutsideSolvedGraph*(): LockIdentity =
  ## The governing lock identity of an edge that no solved graph reaches.
  ##
  ## Some edges genuinely have no solved package instance behind them: a
  ## workspace `git clone`, a dev-environment materialisation that runs before
  ## any solve, a profile-compile edge whose inputs are all repo-local. Their
  ## honest governing graph is the EMPTY one for this platform, and this is a
  ## real recompute over it rather than a sentinel constant.
  ##
  ## **It is not a default, and the distinction is the whole of §7.2.** A
  ## default is a value the construction path supplies when the author says
  ## nothing; this is a value the author must name in their own source. That
  ## makes it greppable, and grep-ability is the point:
  ##
  ## ```
  ## grep -rn lockIdentityOutsideSolvedGraph libs/ apps/
  ## ```
  ##
  ## enumerates every edge not yet wired to a real solved graph — a ledger of
  ## remaining work rather than a silent hole. §7.2's objection to convention
  ## is that "a single edge whose fingerprint forgets the governing lock
  ## identity is a silent poisoning vector"; an edge that says out loud which
  ## graph governs it, even when that graph is empty, is not silent.
  ##
  ## If it later turns out two such edges MUST differ, §6.2 says what to do:
  ## "the correct response is to find the missing input and add it — never to
  ## add the label."
  emptySolvedGraphIdentity(currentPlatformId())

# ---------------------------------------------------------------------------
# §6.3 — the provenance side table
# ---------------------------------------------------------------------------

proc initLockProvenance*(): LockProvenance =
  LockProvenance(byIdentity: initTable[string, seq[string]]())

proc recordBinding*(p: var LockProvenance; identity: LockIdentity;
                    name: string) =
  ## Record that lock-file name `name` resolved to `identity`. Idempotent, and
  ## ADDITIVE — a second name for one identity joins the set rather than being
  ## dropped (the BuildXL `TryAdd` behaviour §6.3 improves on). Names are kept
  ## sorted so `namesFor` and every diagnostic built on it are deterministic.
  if not p.byIdentity.hasKey(string(identity)):
    p.byIdentity[string(identity)] = @[]
  if name notin p.byIdentity[string(identity)]:
    p.byIdentity[string(identity)].add(name)
    p.byIdentity[string(identity)].sort()

proc namesFor*(p: LockProvenance; identity: LockIdentity): seq[string] =
  ## Every lock-file name that resolved to `identity`, sorted. Empty when the
  ## identity is unknown to the table.
  p.byIdentity.getOrDefault(string(identity), @[])

proc identities*(p: LockProvenance): seq[LockIdentity] =
  ## Every recorded identity, sorted, so callers that enumerate the table
  ## produce stable output.
  var keys: seq[string] = @[]
  for k in p.byIdentity.keys: keys.add(k)
  keys.sort()
  result = @[]
  for k in keys: result.add(LockIdentity(k))

proc isShared*(p: LockProvenance; identity: LockIdentity): bool =
  ## True when more than one lock-file name resolved to `identity`.
  p.namesFor(identity).len > 1

proc describeSharing*(p: LockProvenance; identity: LockIdentity): string =
  ## The §6.3 diagnostic line for `identity`, phrased as SHARING.
  ##
  ## §6.3 is explicit that the phrasing is part of the requirement: "A
  ## collision in the provenance table means genuine sharing, not a lost name.
  ## … `repro graph` should present it as such — *'`hostTools` and
  ## `targetRuntime` resolved identically; artifacts shared'* — and never as a
  ## warning." So this renderer emits no "warning", no "conflict", and no
  ## "collision"; a reader who is trained to avoid this outcome has been
  ## trained to avoid a correct one.
  let names = p.namesFor(identity)
  if names.len == 0:
    return ""
  if names.len == 1:
    return "`" & names[0] & "`; artifacts under " & string(identity)
  var rendered = ""
  for i, n in names:
    if i > 0:
      rendered.add(if i == names.len - 1: " and " else: ", ")
    rendered.add("`" & n & "`")
  rendered & " resolved identically; artifacts shared"

const
  LockFileIdentityLabel* = "lockFile: "
  LockFileNamesLabel* = "lockFileNames: "
    ## The labels `repro why`'s text renderer prints. Exported so a test can
    ## bind the CLI's exact output without re-typing a literal that could
    ## drift away from the renderer.

proc lockProvenanceReportLines*(p: LockProvenance;
                                identity: LockIdentity): seq[string] =
  ## The lines `repro why` prints for an action's governing lock file.
  ##
  ## Corpus case NLF-ID-5 asserts on this: "`repro why` reports both names
  ## for a shared artifact, as sharing rather than as a warning." The two
  ## defects it catches are (a) a lossy side table that drops the second name
  ## and (b) "an implementation that reports the collapse as a problem, which
  ## would train users to avoid a correct and desirable outcome."
  ##
  ## The identity line comes first and is always present — it is the key, and
  ## it is what an operator correlates against a cache entry. The names line
  ## is provenance and is omitted when nothing has been recorded, because an
  ## empty `lockFileNames:` reads as "no lock file" rather than "no binding
  ## recorded in this process".
  result = @[LockFileIdentityLabel & string(identity)]
  let names = p.namesFor(identity)
  if names.len > 0:
    result.add(LockFileNamesLabel & p.describeSharing(identity))
