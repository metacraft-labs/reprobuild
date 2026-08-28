## NLF-M9 — per-instance selection status survives write → read.
##
## Named-Lock-Files design §5.6 (owner decision, 2026-08-21). The milestone's
## second deliverable: "the status survives the lock write/read round-trip, or
## is recomputable from what does — state which, and why."
##
## **It is PERSISTED, not recomputed, and the reason is structural.** A lock
## document records the solve's OUTPUT — concrete versions, variant
## assignments, source identities. It carries no dependency edges and no
## variant-conditioned gates, and selection is a property of exactly those: it
## is reachability from a root along edges whose gates fired. Nothing in the
## document determines it. Recomputing it would mean re-reading the solver
## INPUTS (`repro.solver`, the recipe sources), which is the step a pinned lock
## exists to avoid — and it would make the answer depend on inputs that may
## have moved since the lock was written, so two readers of the same lock could
## disagree. A recorded fact cannot drift from itself.
##
## ## What makes this discriminating rather than tautological
##
## The mix matters. A round-trip over an all-selected graph passes against a
## writer that emits nothing and a reader that answers "selected" to
## everything — which is precisely the pre-M9 behaviour. So the graph written
## here is produced by a REAL SOLVE with a dormant variant-conditioned arm, so
## it genuinely contains both statuses, and the unselected instance is what the
## round-trip has to carry.
##
## The final case pins the reverse direction: a v2 document with NO `selection`
## key — the shape every lock written before this milestone has — reads as
## `selected`, reproducing the status quo rather than retroactively inventing
## the unusual claim for locks that never made it.
##
## Test-double policy: NO mocks, doubles, or fakes. A real `solve()` against
## real `libclingo`, a real lock document on a real filesystem, read back by
## the product's own `parseSolvedGraphLock` / `parseLockedDependencies`.

import std/[os, strutils, tables, tempfiles, unittest]

import repro_lock
import repro_solver

proc dormantArmSolution(): UnifiedSolution =
  ## `app` requires `openssl` only when `enableTLS` is true; the gate is off,
  ## so `openssl` (and `zlib` behind it) are in the graph unselected while
  ## `app` is selected. A genuine mix, produced by the solver rather than
  ## hand-stamped.
  let enableTls = newBoolVariant("enableTLS",
    contributions = [contribution(vpSet, "false")])
  solve([enableTls], [
    newPackage("app",
      versions = ["0.1.0"],
      depends = [newConditionalDependency(
        "openssl", ">=3.0", "enableTLS", "true")]),
    newPackage("openssl",
      versions = ["1.1.0", "3.0.0"],
      depends = [newDependency("zlib", ">=1.0")]),
    newPackage("zlib", versions = ["1.3.1"])])

suite "NLF-M9: selection status survives the lock round trip":

  test "a mixed graph writes and reads back with the same statuses":
    let sol = dormantArmSolution()
    # Precondition: the solve really did produce a mix. Without this the rest
    # of the case could pass over a uniform graph and prove nothing.
    require sol.selected["app"] == ssSelected
    require sol.selected["openssl"] == ssUnselected
    require sol.selected["zlib"] == ssUnselected

    let dir = createTempDir("nlf-m9-roundtrip-", "")
    defer: removeDir(dir)
    let lockPath = dir / "repro.lock"
    writeFile(lockPath,
      serializeSolvedGraphLock(solutionToLock(sol, "amd64-linux", "")))

    let reread = parseSolvedGraphLock(readFile(lockPath))
    var byName: Table[string, LockedPackage]
    for p in reread.packages:
      byName[p.name] = p
    check byName["app"].selection == ssSelected
    check byName["openssl"].selection == ssUnselected
    check byName["zlib"].selection == ssUnselected

    # And back into the record the build path consumes.
    let recovered = lockToSolution(reread)
    for name in sol.packages.keys:
      check recovered.selected[name] == sol.selected[name]

  test "the unified v2 reader recovers the same statuses":
    # `parseLockedDependencies` is a second reader over the same bytes
    # (`repro lock refresh` writes through it). A field carried by one reader
    # and dropped by the other is the writer/reader drift this module's header
    # already records once.
    let sol = dormantArmSolution()
    let doc = serializeSolvedGraphLock(solutionToLock(sol, "amd64-linux", ""))
    let ld = parseLockedDependencies(doc)
    var byName: Table[string, LockedPackage]
    for p in ld.packages:
      byName[p.name] = p
    check byName["app"].selection == ssSelected
    check byName["openssl"].selection == ssUnselected

  test "the document actually carries the fact":
    # Guards the degenerate pass: a writer that emits nothing and a reader
    # that answers `ssSelected` to everything would satisfy an all-selected
    # round-trip. The bytes must say it.
    let sol = dormantArmSolution()
    let doc = serializeSolvedGraphLock(solutionToLock(sol, "amd64-linux", ""))
    check "selection = \"unselected\"" in doc
    check "selection = \"selected\"" in doc

  test "a v2 document without the key reads as selected":
    # The shape of every lock written before NLF-M9. The status-quo reading is
    # the only one that changes no behaviour for an existing lock.
    let legacy = """
schema = "reprobuild.solved-graph-lock.v2"

[lock]
platform = "amd64-linux"
optimal = true
inputs_digest = "fnv1a64:0000000000000000"
variants = []
packages = [{ name = "nim", version = "2.2.0", source = "nim" }]
deps = []
"""
    let parsed = parseSolvedGraphLock(legacy)
    check parsed.packages.len == 1
    check parsed.packages[0].selection == ssSelected
    check lockToSolution(parsed).selected["nim"] == ssSelected
