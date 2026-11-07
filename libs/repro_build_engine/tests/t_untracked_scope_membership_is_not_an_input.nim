## An enumerated directory in an UNTRACKED scope carries no membership digest.
##
## Spec: `Incremental-Invalidation.md` §"Validation Criteria", the second
## mandatory exemption ("A second exemption is mandatory for the same reason,
## and it is a CLASSIFICATION rather than a list"). Derived from the root
## classification the workspace declares — read-only / writable / untracked,
## `Filesystem-Policy-And-Observed-Inputs.md` §"Read-Only Versus Writable
## Roots" — and never from a list of well-known paths.
##
## WHAT THE MEASURED DEFECT WAS. Tools search UPWARD. The dev-env
## provider-compile edge is a `nim c`, and Nim's module and config search
## enumerates every ancestor of its working directory: 449 recorded
## enumerations on one activation, among them `/`, `/Users/`, `$HOME`,
## `$HOME/.cache/` and `/nix/`
## (`issues/2026-09-24-dev-env-never-converges-on-a-fresh-project.md`, the
## fifth cause). So the edge's key depended on the immediate membership of the
## filesystem root and of the user's home directory, which any unrelated
## process changes — and the edge could not converge across processes at all.
##
## NO MOCKS, AND NO FILESYSTEM. `cacheEnumeratedDirectories`,
## `declaredFilesystemRoots` and `untrackedEnumerationScope` are pure folds
## over strings, so the evidence here is a literal `PathSetEvidence` and the
## roots are literal paths — the same precedent and the same reason
## `t_self_written_set_is_derived.nim` states. `action()` is the real
## constructor and `declaredFilesystemRoots` is the real derivation the engine
## and the CLI both call; nothing is re-implemented here.
##
## NOT VACUOUS ON ANY HOST, which is a property this file had to be designed
## for. A test that pins an exemption on a path which happens to be untracked
## on the machine running it asserts nothing on a machine laid out
## differently — a reviewer found exactly that shape in this campaign, live on
## macOS and vacuous on Linux. Every root and every enumerated path below is
## SYNTHETIC and absolute, built under one unit root per platform, so the
## tracked/untracked relation between them is a property of the strings and
## not of the host. The one real path asserted on is `/` (or `C:/`), whose
## relation to a project root under `UnitRoot` is the same everywhere.
##
## BOTH DIRECTIONS, every time. Dropping a genuine input from a key serves a
## stale result, which is strictly worse than the miss being fixed. So every
## exemption asserted below is paired with a retention an over-broad filter
## would fail: a directory inside the project, a directory inside the work
## root, a tracked root NESTED under two exempt ancestors, the declared-input
## escape, and the whole fail-closed arm where no classification was declared.

import std/[strutils, unittest]

import repro_build_engine
import repro_local_store

const
  UnitRoot =
    when defined(windows): "C:/repro-untracked-scope-unit"
    else: "/repro-untracked-scope-unit"
  FsRoot =
    when defined(windows): "C:/"
    else: "/"
  ProjectRoot = UnitRoot & "/proj"
  WorkRoot = UnitRoot & "/work"
  # The shape the measured host has: the default store root is
  # `$HOME/.cache/repro/store`, so the store is a tracked root with TWO
  # untracked ancestors above it.
  HomeRoot = UnitRoot & "/home"
  StoreRoot = HomeRoot & "/.cache/repro/store"
  # Where the action under test declares its output. Under no declared root
  # and in no enumerated directory — see `enumeratingAction`.
  OutputRoot = UnitRoot & "/outputs"

proc norm(path: string): string =
  path.replace('\\', '/')

proc hasPath(paths: openArray[string]; wanted: string): bool =
  for path in paths:
    if path.norm == wanted.norm:
      return true

proc enumeratingAction(declaredInputs: openArray[string] = []): BuildAction =
  ## An ordinary action rooted in the project, with no ignored prefixes, no
  ## tool roots and no declared write root, so the only filter in play below
  ## is the untracked-scope one.
  ##
  ## THE OUTPUT DELIBERATELY SITS IN NO ENUMERATED DIRECTORY, and not in the
  ## project either. `cacheEnumeratedDirectories` also elides the directory a
  ## declared output sits in — `selfWrittenDirectoryKeys`, derived from the
  ## output declaration — so an output under `ProjectRoot` would make every
  ## retention asserted below pass or fail for that filter instead of this
  ## one. An earlier revision of this file declared `ProjectRoot/out.stamp`
  ## and the project-root retentions reddened the moment the self-written
  ## derivation landed beside it, which is how the overlap was found.
  ## `t_untracked_ancestor_change_does_not_re_run_an_edge.nim` states the
  ## same requirement for its fixture.
  action("t-enumerate", ["/bin/true"], cwd = ProjectRoot,
    inputs = declaredInputs,
    outputs = [OutputRoot & "/out.stamp"],
    cacheable = true,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc evidenceOf(act: BuildAction; dirs: openArray[string]): PathSetEvidence =
  result.declaredInputs = act.inputs
  result.declaredOutputs = act.outputs
  result.monitorDirectoryEnumerations.observeAll(
    result.evidenceProvenance, evcMonitorCapture, dirs)

const Enumerations = [
  # Above the outermost tracked root — what an upward search walks through.
  FsRoot,
  UnitRoot,
  HomeRoot,
  HomeRoot & "/.cache",
  # Under no declared root at all, and not an ancestor of one.
  UnitRoot & "/unrelated",
  # Inside the declared roots.
  ProjectRoot,
  ProjectRoot & "/src",
  WorkRoot & "/nimcache",
  # A tracked root nested beneath two exempt ancestors, and a directory
  # inside it.
  StoreRoot,
  StoreRoot & "/prefixes/nim",
]

proc declaredRoots(): seq[LogicalRoot] =
  declaredFilesystemRoots(ProjectRoot, WorkRoot, StoreRoot)

suite "untracked scope membership is not an input":

  test "an ancestor above the outermost tracked root carries no membership":
    let act = enumeratingAction()
    let tracked = trackedFilesystemRootPaths(declaredRoots())
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(Enumerations),
      tracked)
    checkpoint("membership-tracked: " & kept.join(", "))
    # GONE: every directory the build declared no interest in.
    check not kept.hasPath(FsRoot)
    check not kept.hasPath(UnitRoot)
    check not kept.hasPath(HomeRoot)
    check not kept.hasPath(HomeRoot & "/.cache")
    check not kept.hasPath(UnitRoot & "/unrelated")
    # STAYED: everything at or under a declared tracked root.
    check kept.hasPath(ProjectRoot)
    check kept.hasPath(ProjectRoot & "/src")
    check kept.hasPath(WorkRoot & "/nimcache")

  test "a tracked root nested inside an exempt region stays tracked":
    # `Incremental-Invalidation.md`: "The individual package directories
    # INSIDE the store stay tracked". The store root here sits under two
    # exempt ancestors (`$HOME` and `$HOME/.cache`), both asserted exempt by
    # the case above, so this is the nesting and not a restatement of it.
    let act = enumeratingAction()
    let tracked = trackedFilesystemRootPaths(declaredRoots())
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(Enumerations),
      tracked)
    check kept.hasPath(StoreRoot)
    check kept.hasPath(StoreRoot & "/prefixes/nim")

  test "no declared classification exempts nothing":
    # §"Rebuild Decision Model": "If any required condition cannot be
    # checked, Reprobuild MUST fail closed." An engine configuration that
    # declares no roots cannot say which directories are above its outermost
    # tracked root, so it exempts none of them — which is also what keeps
    # every pre-existing caller byte-exact.
    let act = enumeratingAction()
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(Enumerations))
    for dir in Enumerations:
      check kept.hasPath(dir)

  test "only the tracked half of the classification is read":
    # The env-proofing clause, as a test rather than as a comment: an
    # `lrkUntracked` entry must not be able to nominate anything. On Windows
    # `declaredFilesystemRoots` derives one of them from `%SystemRoot%`, so
    # reading the untracked half would be exactly the
    # "configurable from the enumerating process's environment" channel
    # §"Validation Criteria" forbids. A classification with no TRACKED entry
    # therefore has an empty tracked set, and an empty tracked set exempts
    # nothing.
    let untrackedOnly = @[
      LogicalRoot(label: "system", path: UnitRoot & "/unrelated",
                  kind: lrkUntracked)]
    check trackedFilesystemRootPaths(untrackedOnly).len == 0
    let act = enumeratingAction()
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(Enumerations),
      trackedFilesystemRootPaths(untrackedOnly))
    check kept.hasPath(UnitRoot & "/unrelated")
    check kept.hasPath(FsRoot)

  test "trailing-slash spellings classify the same directory the same way":
    # The monitor demonstrably emits both spellings for one directory, and
    # every ancestor enumeration in the measured issue arrived WITH a
    # trailing slash (`/`, `/Users/`, `/Users/zahary/`) while declared roots
    # arrive without. Here the cliff would point the FAIL-OPEN way: a tracked
    # root spelled with a trailing slash that stopped matching its own
    # directory would drop the project root's membership.
    let act = enumeratingAction()
    let slashed = [UnitRoot & "/", HomeRoot & "/", ProjectRoot & "/",
      ProjectRoot & "/src/", StoreRoot & "/"]
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(slashed),
      trackedFilesystemRootPaths(declaredRoots()))
    checkpoint("membership-tracked: " & kept.join(", "))
    check not kept.hasPath(UnitRoot & "/")
    check not kept.hasPath(HomeRoot & "/")
    check kept.hasPath(ProjectRoot & "/")
    check kept.hasPath(ProjectRoot & "/src/")
    check kept.hasPath(StoreRoot & "/")
    # And the other side of the same cliff: roots spelled with a trailing
    # slash still match. `declaredFilesystemRoots` does not produce that
    # spelling today, so this pins the normalization rather than a caller.
    let slashedRoots = trackedFilesystemRootPaths(@[
      LogicalRoot(label: "project", path: ProjectRoot & "/",
                  kind: lrkTracked)])
    check not slashedRoots.untrackedEnumerationScope(ProjectRoot)
    check not slashedRoots.untrackedEnumerationScope(ProjectRoot & "/src")
    check slashedRoots.untrackedEnumerationScope(UnitRoot)

  test "a declared input directory keeps its membership whatever its scope":
    # An author who NAMED a directory as an input of this action has stated
    # the interest the classification is otherwise inferring the absence of.
    # Same retention the tool/ignored-root filter beside it already grants.
    let outside = UnitRoot & "/unrelated"
    let act = enumeratingAction([outside])
    let kept = act.cacheEnumeratedDirectories(act.evidenceOf(Enumerations),
      trackedFilesystemRootPaths(declaredRoots()))
    check kept.hasPath(outside)
    # …and the retention is the DECLARATION's, not a blanket one: its sibling
    # ancestors are still exempt.
    check not kept.hasPath(UnitRoot)

  test "the classification is derived, never a list of well-known paths":
    # `Filesystem-Policy-And-Observed-Inputs.md` §"The self-written set is
    # derived, never listed": a list of exempt ancestors is correct only
    # until the next machine has a layout nobody enumerated. The complement
    # has no such failure mode, and this is the assertion of that property:
    # move the project to a root spelled nothing like the one above and the
    # SAME two lines classify it, with no entry added anywhere.
    const Alien = UnitRoot & "/opt/weird layout/x"
    let tracked = trackedFilesystemRootPaths(
      declaredFilesystemRoots(Alien, "", ""))
    check not tracked.untrackedEnumerationScope(Alien)
    check not tracked.untrackedEnumerationScope(Alien & "/src")
    check tracked.untrackedEnumerationScope(UnitRoot & "/opt")
    # The match is anchored on a path BOUNDARY and not on the string: a
    # SIBLING whose name merely starts with a tracked root's is not under it.
    # Pinned because a plain `startsWith(root)` reddens nothing else here —
    # it only ever claims MORE directories are tracked, so it hides as a
    # performance cliff rather than as a failure.
    check tracked.untrackedEnumerationScope(Alien & "-sibling")
    check tracked.untrackedEnumerationScope(FsRoot)
    # The store root the measured host uses is a per-user cache path with no
    # literal to hard-code, which is the other half of why there is no list.
    check resolvedStoreRootOrEmpty().len > 0
