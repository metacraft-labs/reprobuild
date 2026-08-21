## NLF-M9 — the control: selected, unselected and absent are THREE states.
##
## Named-Lock-Files design §5.6 (owner decision, 2026-08-21). The two readings
## the owner rejected each collapsed two of these into one:
##
##   * gating package *presence* in the encoder would have made "unselected"
##     and "absent" the same state, hard-wiring one policy into the solver
##     where it could not be varied per consumer;
##   * leaving things as they were made "unselected" and "selected" the same
##     state, so no consumer could apply any policy at all.
##
## The decision is neither. This case is the standing guard on that: it pins
## all three states apart, and it pins the boundary of the milestone — the
## fact is recorded, and NOTHING downstream acts on it yet.
##
## ## The four properties, and why each is load-bearing
##
## 1. **Unselected ≠ absent in the solved graph.** An unselected instance is
##    still in `packages` and still carries a version. An implementation that
##    dropped it would report a smaller graph.
## 2. **Unselected ≠ absent in the lock document.** `solutionToLock` copies
##    every instance, unfiltered, exactly as before. Whether an unselected
##    instance belongs in the lock is one of §5.6's three open policy
##    questions and this milestone answers none of them.
## 3. **Absence MOVES the lock identity.** Dropping an instance from the graph
##    is a different graph and must key differently — otherwise property 2
##    would be unobservable.
## 4. **Selection status does NOT move the lock identity.** Flipping the fact
##    on an otherwise identical graph must produce the SAME key. This is the
##    milestone's lane marker: `lockIdentity` is §6.2's formula over the
##    canonical solved graph, and adding a new input to it is a separate
##    milestone with its own baseline. Properties 3 and 4 together are what
##    make the pair discriminating — an implementation that hashed the new
##    field would pass 3 and fail 4; one that hashed nothing at all would
##    pass 4 and fail 3.
##
## Test-double policy: NO mocks, doubles, or fakes. Real `solve()` output for
## the graph shape, the product's own `solutionToLock` and `lockIdentityOf`
## for the assertions.

import std/[tables, unittest]

import repro_lock
import repro_solver

proc mixedGraph(): UnifiedSolution =
  ## `app` (selected) → dormant conditional arm → `openssl`, `zlib`
  ## (unselected). `absent-package` is deliberately never declared.
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

proc packageNames(lock: SolvedGraphLock): seq[string] =
  result = @[]
  for p in lock.packages: result.add(p.name)

suite "NLF-M9: selection is not the same as absence":

  test "three distinct states are distinguishable in the solved graph":
    let sol = mixedGraph()

    # SELECTED — present, and recorded as required.
    check "app" in sol.packages
    check sol.selected["app"] == ssSelected

    # UNSELECTED — present, carrying a concrete version, recorded as required
    # by nothing. Not a hole in the graph.
    check "openssl" in sol.packages
    check sol.packages["openssl"].len > 0
    check sol.selected["openssl"] == ssUnselected

    # ABSENT — not in the graph at all, and therefore not in the status table
    # either. Asking for its status is not answerable, which is the point:
    # `getOrDefault` here would manufacture `ssSelected` for a package that
    # does not exist.
    check "absent-package" notin sol.packages
    check "absent-package" notin sol.selected

  test "an unselected instance still appears in the lock document":
    # Property 2 — the boundary of the milestone. Filtering here would be a
    # policy change, and §5.6 assigns that to its own milestone.
    let lock = solutionToLock(mixedGraph(), "amd64-linux", "")
    let names = packageNames(lock)
    check names.len == 3
    check "openssl" in names
    check "zlib" in names
    check "app" in names

  test "absence moves the lock identity; selection status does not":
    let sol = mixedGraph()
    let full = solutionToLock(sol, "amd64-linux", "")

    # (a) FLIP THE FACT, change nothing else. Same key.
    var flipped = full
    for i in 0 ..< flipped.packages.len:
      flipped.packages[i].selection =
        if flipped.packages[i].selection == ssSelected: ssUnselected
        else: ssSelected
    check lockIdentityOf(flipped) == lockIdentityOf(full)

    # (b) DROP an instance. Different key — so (a) is a real observation
    #     about the identity formula and not an artefact of an identity that
    #     never changes.
    var dropped = full
    var kept: seq[LockedPackage] = @[]
    for p in dropped.packages:
      if p.name != "zlib": kept.add(p)
    dropped.packages = kept
    check dropped.packages.len == full.packages.len - 1
    check lockIdentityOf(dropped) != lockIdentityOf(full)

  test "the three states survive into the reconstructed solution":
    # A consumer reading a lock must see the same three states the solve saw.
    let sol = mixedGraph()
    let recovered = lockToSolution(solutionToLock(sol, "amd64-linux", ""))
    check recovered.selected["app"] == ssSelected
    check recovered.selected["openssl"] == ssUnselected
    check "absent-package" notin recovered.selected
    check "absent-package" notin recovered.packages
